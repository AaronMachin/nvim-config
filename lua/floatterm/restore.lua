-- Reopens the floating terminal's tabs when nvim starts again in the same folder.
--
-- With the reopen_tabs setting on, each nvim started in a folder (no files given)
-- keeps its own saved set of tabs, in stdpath("data")/floatterm-tabs/<folder>/<id>.json
-- (the folder with / as %). A set holds the folder, when it was last saved and the
-- tabs. It's written as tabs change (a second or two later), every 30 seconds while
-- there are tabs, when nvim loses focus and on quit, always to a temporary file that
-- is then renamed over the set, so a crash or power cut loses a couple of seconds at
-- most and never leaves half a set. No save waits on `ps` for what each shell runs:
-- the 30-second one asks the tab bar to find out for the next save.
--
-- The set a running nvim owns has <id>.lock beside it, holding its pid and server
-- address. The lock only counts while that pid is a running nvim listening at that
-- address (a crashed nvim's pid may since belong to another one). A lock is made whole
-- or not at all, and replacing a crashed nvim's is done by one nvim at a time, so two
-- nvims never both own a set. An empty lock (from an older version, or cut short)
-- counts for LOCK_GRACE after it was written.
--
-- Starting nvim in the folder:
--   another nvim there has tabs  asks whether to open the same tabs (a copy, which
--                                this nvim then owns) or start fresh
--   one saved set                opens it
--   several saved sets           a picker of them (Enter opens, Ctrl+d deletes),
--                                plus "Start fresh"
-- Starting fresh makes a set only once the first tab opens. The 10 most recently saved
-- sets are kept; older ones go.
--
-- Reopening a set:
--   Claude tabs resume their conversation (`claude --resume <id>`) where it ran. One
--   whose conversation was never written (Claude writes it after the first message)
--   starts a fresh `claude` in its folder instead.
--   Shell tabs are fresh shells in the same folder. What last ran in one is kept on
--   the record as last_command, but never run again.
--   Every tab keeps its uid and parent (lua/floatterm/groups); group headings come
--   back as headings. A child whose parent didn't come back loses the link quietly.
-- A Claude tab that can't be reopened (its folder is gone, or its resume exits
-- straight away) is kept in the set and tried once more next time.
--
-- Opening nvim on a file (as git's editor, say), on stdin (`-`), with a session (-S),
-- an error file (-q) or a +command, and nvim without a UI (headless) do none of this.

local M = {}

-- Fields rather than locals so tests can point them somewhere else; the vim.g
-- overrides are for tests too, set with --cmd before the config loads.
M.dir = vim.g.floatterm_tabs_dir or (vim.fn.stdpath "data" .. "/floatterm-tabs")
-- Lets headless nvim restore and save, for tests.
M.allow_headless = vim.g.floatterm_restore_headless or false

-- A resumed Claude that exits sooner than this didn't resume.
local RESUME_GRACE = 5000
-- How many times a tab that couldn't be reopened is tried before it's dropped.
local ATTEMPTS = 2
-- How long after a change the set is written. Not reset by further changes, as a
-- working Claude's title changes every second or so.
local SAVE_DELAY = 1500
local SAVE_EVERY = 30000
-- Sets kept per folder.
local KEEP = 10
-- An empty or unreadable lock counts as another nvim's for this long after it was
-- written, as it may be one being written now.
local LOCK_GRACE = 3
-- A claim on replacing a crashed nvim's lock older than this was left by an nvim that
-- crashed while making it.
local CLAIM_GRACE = 10

local folder = nil
local done = false
local restoring = false
-- The id of the set this nvim owns and saves into, or nil until it has one.
local current = nil
-- Saved tabs that couldn't be reopened this time, written into the next save.
local carried = {}
local pending = nil
local ticker = nil

local function folder_dir()
  return M.dir .. "/" .. folder:gsub("/", "%%")
end

local function set_path(id)
  return folder_dir() .. "/" .. id .. ".json"
end

local function lock_path(id)
  return folder_dir() .. "/" .. id .. ".lock"
end

-- Options whose next argument is theirs, not a file.
local TAKES_ARG = {
  ["-u"] = true,
  ["-i"] = true,
  ["-c"] = true,
  ["--cmd"] = true,
  ["--listen"] = true,
  ["--startuptime"] = true,
  ["-s"] = true,
  ["-w"] = true,
  ["-W"] = true,
  ["-t"] = true,
  ["-T"] = true,
}

-- Whether nvim was started to open something other than a folder: stdin (-), a session
-- (-S), an error file (-q) or a +command.
local function opens_something()
  local argv = vim.v.argv
  local i = 2
  while i <= #argv do
    local arg = argv[i]
    if arg == "--" then
      return false
    elseif TAKES_ARG[arg] then
      i = i + 1
    elseif arg == "-" or arg:match "^%-S" or arg:match "^%-q" or arg:match "^%+" then
      return true
    end
    i = i + 1
  end
  return false
end

-- The folder nvim was started in, or nil when it was given files to open.
local function started_folder()
  if opens_something() then
    return nil
  end
  local argc = vim.fn.argc()
  if argc == 0 then
    return vim.uv.fs_realpath(vim.uv.cwd())
  end
  if argc == 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
    return vim.uv.fs_realpath(vim.fn.argv(0))
  end
  return nil
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, file:read "*a", { luanil = { object = true } })
  file:close()
  return ok and type(decoded) == "table" and decoded or nil
end

-- Writes `text` to a temporary file beside `path`, flushed to disk, then renames it
-- over `path`, so the file is always either the old or the new one in full.
local function write_atomic(path, text)
  local tmp = path .. ".tmp" .. vim.fn.getpid()
  local fd = vim.uv.fs_open(tmp, "w", 420)
  if not fd then
    return false
  end
  local written = vim.uv.fs_write(fd, text)
  vim.uv.fs_fsync(fd)
  vim.uv.fs_close(fd)
  if written ~= #text or not vim.uv.fs_rename(tmp, path) then
    os.remove(tmp)
    return false
  end
  return true
end

-- Whether `pid` is a running nvim, so a lock left by one that crashed (or a pid since
-- reused by something else) doesn't count.
local function nvim_running(pid)
  local ok, found = pcall(vim.api.nvim_get_proc, pid)
  return ok and found ~= nil and (found.name or ""):match "nvim" ~= nil
end

-- Whether an nvim is listening at `server`. A crashed nvim's socket file can be left
-- behind, so it's connected to rather than looked for.
local function listening(server)
  if server == vim.v.servername then
    return true
  end
  local mode = server:match "^[^/]+:%d+$" and "tcp" or "pipe"
  local ok, channel = pcall(vim.fn.sockconnect, mode, server)
  if ok and type(channel) == "number" and channel > 0 then
    vim.fn.chanclose(channel)
    return true
  end
  return false
end

local function age(path)
  local stat = vim.uv.fs_stat(path)
  return stat and (os.time() - stat.mtime.sec) or math.huge
end

local function is_mine(held)
  return held ~= nil
    and tonumber(held.pid) == vim.fn.getpid()
    and (held.server == nil or held.server == vim.v.servername)
end

-- Whether the lock at `path` (read as `held`) is another running nvim's. A lock from
-- before the address was kept counts by its pid alone.
local function live(path, held)
  if not held then
    return vim.uv.fs_stat(path) ~= nil and age(path) < LOCK_GRACE
  end
  local pid = tonumber(held.pid)
  if not pid or is_mine(held) or not nvim_running(pid) then
    return false
  end
  return type(held.server) ~= "string" or held.server == "" or listening(held.server)
end

-- The pid of the other running nvim holding `path` (true while a lock is being
-- written), or nil.
local function held_by(path)
  local held = read_json(path)
  if live(path, held) then
    return held and tonumber(held.pid) or true
  end
  return nil
end

local function my_lock()
  return vim.json.encode { pid = vim.fn.getpid(), server = vim.v.servername }
end

-- Writes `text` to a temporary file and links it in at `path` only if nothing is
-- there, so the file appears whole or not at all. False when `path` exists.
local function create_whole(path, text)
  local tmp = path .. ".new" .. vim.fn.getpid()
  local fd = vim.uv.fs_open(tmp, "w", 420)
  if not fd then
    return false
  end
  vim.uv.fs_write(fd, text)
  vim.uv.fs_fsync(fd)
  vim.uv.fs_close(fd)
  local ok = vim.uv.fs_link(tmp, path)
  os.remove(tmp)
  return ok == true
end

-- Takes the lock on set `id`. False when another running nvim holds it, or is taking
-- it at the same moment.
local function take_lock(id)
  vim.fn.mkdir(folder_dir(), "p")
  local path = lock_path(id)
  if create_whole(path, my_lock()) then
    return true
  end
  local held = read_json(path)
  if is_mine(held) then
    return true
  end
  if live(path, held) then
    return false
  end
  -- A crashed nvim's lock. Only the nvim holding the claim replaces it, having read it
  -- again: another may have replaced it since it was read above.
  local claim = path .. ".claim"
  if not create_whole(claim, my_lock()) then
    if age(claim) < CLAIM_GRACE then
      return false
    end
    os.remove(claim)
    if not create_whole(claim, my_lock()) then
      return false
    end
  end
  local ok = false
  held = read_json(path)
  if is_mine(held) then
    ok = true
  elseif not live(path, held) and write_atomic(path, my_lock()) then
    ok = is_mine(read_json(path))
  end
  os.remove(claim)
  return ok
end

local function release_lock()
  if not current then
    return
  end
  local held = read_json(lock_path(current))
  if held and tonumber(held.pid) == vim.fn.getpid() then
    os.remove(lock_path(current))
  end
end

local function new_id()
  return os.date "%Y%m%d-%H%M%S" .. "-" .. vim.fn.getpid()
end

-- Every set saved for this folder, most recently saved first, as { id, saved_at,
-- tabs, live } (live: the pid of the other nvim that owns it).
local function list_sets()
  local found = {}
  local dir = folder_dir()
  for name, kind in vim.fs.dir(dir) do
    local id = kind == "file" and name:match "^(.+)%.json$"
    if id then
      local set = read_json(dir .. "/" .. name)
      if set and type(set.tabs) == "table" then
        table.insert(found, {
          id = id,
          saved_at = tonumber(set.saved_at) or 0,
          tabs = set.tabs,
          live = held_by(lock_path(id)),
        })
      end
    end
  end
  table.sort(found, function(a, b)
    return a.saved_at > b.saved_at
  end)
  return found
end

function M.delete_set(id)
  os.remove(set_path(id))
  if not held_by(lock_path(id)) then
    os.remove(lock_path(id))
  end
end

-- Keeps the KEEP most recently saved sets with tabs, and this nvim's own and any
-- another running nvim owns whatever their age. Clears locks left by crashed nvims.
local function prune()
  local kept = 0
  for _, set in ipairs(list_sets()) do
    local mine = set.id == current
    if not (mine or set.live) then
      if #set.tabs == 0 or kept >= KEEP then
        M.delete_set(set.id)
      else
        kept = kept + 1
      end
    elseif #set.tabs > 0 then
      kept = kept + 1
    end
  end
  for name, kind in vim.fs.dir(folder_dir()) do
    local id = kind == "file" and name:match "^(.+)%.lock$"
    if id and id ~= current and not vim.uv.fs_stat(set_path(id)) and not held_by(lock_path(id)) then
      os.remove(lock_path(id))
    end
    -- A temporary file from a write that nvim died in the middle of. (Not a migration
    -- cut short, which is finished at the next start; see migrate.)
    local pid = kind == "file"
      and not name:match "^migrating"
      and tonumber(name:match "%.tmp(%d+)$" or name:match "%.new(%d+)$")
    if pid and pid ~= vim.fn.getpid() and not nvim_running(pid) then
      os.remove(folder_dir() .. "/" .. name)
    end
  end
end

-- Makes the old file `taken` (see migrate) a set, and removes it.
local function finish_migration(taken)
  local stat = vim.uv.fs_stat(taken)
  local tabs = read_json(taken)
  if stat and tabs and #tabs > 0 then
    local set = { folder = folder, saved_at = stat.mtime.sec, tabs = tabs }
    local id = os.date("%Y%m%d-%H%M%S", stat.mtime.sec) .. "-migrated"
    if not write_atomic(set_path(id), vim.json.encode(set)) then
      return
    end
  end
  os.remove(taken)
end

-- Before sets, a folder's tabs were one file, <folder>.json beside the folders, with a
-- .lock for the nvim using it. That file becomes a set of its own. Left alone while
-- an nvim from before is still running there, as it rewrites the file on quit.
--
-- It's renamed to migrating-<pid>.old first, so only one nvim starting at the same
-- moment migrates it, and a migration an nvim crashed part-way through is finished at
-- the next start (migrating.tmp<pid> is the name it had before).
local function migrate()
  for name, kind in vim.fs.dir(folder_dir()) do
    local pid = kind == "file" and tonumber(name:match "^migrating%-(%d+)%.old$" or name:match "^migrating%.tmp(%d+)$")
    if pid and (pid == vim.fn.getpid() or not nvim_running(pid)) then
      finish_migration(folder_dir() .. "/" .. name)
    end
  end

  local old = M.dir .. "/" .. folder:gsub("/", "%%") .. ".json"
  local stat = vim.uv.fs_stat(old)
  if not stat or held_by((old:gsub("%.json$", ".lock"))) then
    return
  end
  vim.fn.mkdir(folder_dir(), "p")
  local taken = folder_dir() .. "/migrating-" .. vim.fn.getpid() .. ".old"
  if not vim.uv.fs_rename(old, taken) then
    return
  end
  finish_migration(taken)
  os.remove((old:gsub("%.json$", ".lock")))
end

-- The tabs as saved: what's open now, then what couldn't be reopened this time.
local function snapshot()
  local saved = {}
  for _, record in ipairs(package.loaded.floatterm and require("floatterm").tabs() or {}) do
    local tab = {
      kind = record.kind,
      cwd = record.cwd,
      label = record.label,
      note_id = record.note_id,
      notes_on = record.notes_on,
      -- Where it sits among the tabs (lua/floatterm/groups).
      uid = record.uid,
      parent_uid = record.parent_uid,
      children_folded = record.children_folded,
      workstream_slug = record.workstream_slug,
      workstream_asked = record.workstream_asked,
    }
    if record.kind == "group" then
      tab.notes_on, tab.note_id = nil, nil
    elseif record.kind == "claude" then
      tab.session_id = record.session_id
      tab.transcript_path = record.transcript_path
      tab.start_ref = record.start_ref
      -- What the tab bar showed, so a resumed tab doesn't come back blank and "new".
      -- Working when saved reads as done once reopened (it stopped mid-way).
      tab.title = record.title ~= record.shell_title and record.title or nil
      tab.last_prompt = record.last_prompt
      tab.status = record.status == "working" and "done" or record.status
      tab.status_since = record.status_since
    else
      -- An idle shell's command is the shell itself, so only a running one counts.
      local ok, tabbar = pcall(require, "floatterm.tabbar")
      local running = record.command and ok and tabbar.is_running(record)
      tab.last_command = running and record.command or record.last_command
    end
    table.insert(saved, tab)
  end
  return vim.list_extend(saved, vim.deepcopy(carried))
end

local function cancel_pending()
  if pending then
    pending:stop()
    pending:close()
    pending = nil
  end
end

-- Writes this nvim's set now, with what each shell was last known to run. `refresh`
-- (the periodic save) also asks the tab bar to find out again with `ps`, which answers
-- in its own time; a change it finds is saved a moment later.
function M.save(refresh)
  cancel_pending()
  if not (folder and done) or not require("floatterm.settings").get "reopen_tabs" then
    return
  end
  if refresh then
    pcall(function()
      require("floatterm.tabbar").refresh()
    end)
  end

  local tabs = snapshot()
  if #tabs == 0 then
    -- A set whose last tab closed is dropped; one that never had tabs is never made.
    if current then
      os.remove(set_path(current))
    end
    return
  end
  if not current then
    local id = new_id()
    if not take_lock(id) then
      return
    end
    current = id
    vim.schedule(function()
      pcall(prune)
    end)
  end
  write_atomic(set_path(current), vim.json.encode { folder = folder, saved_at = os.time(), tabs = tabs })
end

local function save_soon()
  if pending or not done then
    return
  end
  pending = vim.uv.new_timer()
  pending:start(
    SAVE_DELAY,
    0,
    vim.schedule_wrap(function()
      pcall(M.save)
    end)
  )
end

local function name_of(tab)
  return tab.label or vim.fn.fnamemodify(tab.cwd or "", ":t")
end

-- "a", "a and b", "a, b and c".
local function join(names)
  if #names < 2 then
    return names[1] or ""
  end
  return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- Whether Claude can still find the conversation: its transcript is where it was,
-- or anywhere under ~/.claude/projects (the session may have moved folders).
local function has_transcript(tab)
  if tab.transcript_path and vim.uv.fs_stat(tab.transcript_path) then
    return true
  end
  local config = vim.env.CLAUDE_CONFIG_DIR or (vim.env.HOME .. "/.claude")
  return #vim.fn.glob(config .. "/projects/*/" .. tab.session_id .. ".jsonl", true, true) > 0
end

-- What happened to each saved tab, reported in one message once every resume has had
-- RESUME_GRACE to fail.
local function new_report()
  return { opened = 0, fresh = {}, failed = {}, dropped = {} }
end

-- Keeps a tab that couldn't be reopened for the next save, or drops it once it has
-- failed ATTEMPTS times.
local function not_reopened(report, tab, reason)
  tab.attempts = (tab.attempts or 0) + 1
  local entry = name_of(tab) .. " (" .. reason .. ")"
  if tab.attempts >= ATTEMPTS then
    table.insert(report.dropped, entry)
  else
    table.insert(carried, tab)
    table.insert(report.failed, entry)
  end
  save_soon()
end

local function notify(report)
  local parts = {}
  if #report.fresh > 0 then
    local several = #report.fresh > 1
    table.insert(
      parts,
      join(report.fresh)
        .. (
          several and " had no conversation yet, so they started fresh"
          or " had no conversation yet, so it started fresh"
        )
    )
  end
  if #report.failed > 0 then
    table.insert(parts, "couldn't resume " .. join(report.failed) .. ", kept for next time")
  end
  if #report.dropped > 0 then
    local them = #report.dropped > 1 and "them" or "it"
    table.insert(parts, "couldn't resume " .. join(report.dropped) .. " again, so gave up on " .. them)
  end
  if #parts == 0 then
    return
  end
  local opened = report.opened .. (report.opened == 1 and " tab" or " tabs")
  local problem = #report.failed + #report.dropped > 0
  vim.notify(
    "floatterm: reopened " .. opened .. "; " .. table.concat(parts, "; "),
    problem and vim.log.levels.WARN or nil
  )
end

-- The last thing a terminal printed, which says why a resume exited.
local function last_line(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    local line = vim.trim(lines[i])
    if line ~= "" then
      return vim.fn.strcharpart(line, 0, 80)
    end
  end
  return nil
end

-- The fields every reopened tab keeps, for floatterm.update.
local function placed(tab)
  return {
    uid = tab.uid or nil,
    parent_uid = tab.parent_uid or vim.NIL,
    children_folded = tab.children_folded or vim.NIL,
    workstream_slug = tab.workstream_slug or vim.NIL,
    workstream_asked = tab.workstream_asked or vim.NIL,
  }
end

local function reopen(tab, report)
  local floatterm = require "floatterm"
  if tab.kind == "group" then
    -- Gone again once restoring is over if none of its children came back.
    local buf = floatterm.new_group { label = tab.label, cwd = tab.cwd, uid = tab.uid }
    floatterm.update(buf, placed(tab))
    return false
  end
  if tab.kind ~= "claude" then
    local cwd = tab.cwd and vim.fn.isdirectory(tab.cwd) == 1 and tab.cwd or folder
    local _, buf = floatterm.new_tab(nil, { cwd = cwd, label = tab.label, show = false })
    floatterm.update(
      buf,
      vim.tbl_extend("force", placed(tab), {
        last_command = tab.last_command or vim.NIL,
        note_id = tab.note_id or vim.NIL,
        notes_on = tab.notes_on or vim.NIL,
      })
    )
    report.opened = report.opened + 1
    return false
  end

  if vim.fn.isdirectory(tab.cwd or "") ~= 1 then
    not_reopened(report, tab, "its folder " .. (tab.cwd or "?") .. " is gone")
    return false
  end

  -- Through agent so the tab gets the IDE connection and counts as its folder's
  -- Claude tab.
  if not (tab.session_id and has_transcript(tab)) then
    local fresh = require("agent").open(tab.cwd, { label = tab.label, show = false })
    floatterm.update(
      fresh,
      vim.tbl_extend("force", placed(tab), { note_id = tab.note_id or vim.NIL, notes_on = tab.notes_on or vim.NIL })
    )
    report.opened = report.opened + 1
    table.insert(report.fresh, name_of(tab))
    return false
  end

  if tab.status == "needs_you" then
    -- Its keys clear "needs you", as for a tab whose hook said so in this nvim.
    pcall(require, "floatterm.claude")
  end
  local buf = require("agent").open(tab.cwd, {
    argv = { "claude", "--resume", tab.session_id },
    label = tab.label,
    session_id = tab.session_id,
    start_ref = tab.start_ref,
    show = false,
  })
  floatterm.update(buf, {
    uid = tab.uid or nil,
    parent_uid = tab.parent_uid or vim.NIL,
    children_folded = tab.children_folded or vim.NIL,
    workstream_slug = tab.workstream_slug or vim.NIL,
    workstream_asked = tab.workstream_asked or vim.NIL,
    note_id = tab.note_id or vim.NIL,
    notes_on = tab.notes_on or vim.NIL,
    title = tab.title or vim.NIL,
    last_prompt = tab.last_prompt or vim.NIL,
    status = tab.status or vim.NIL,
    status_since = tab.status_since or vim.NIL,
  })
  report.opened = report.opened + 1
  local started = vim.uv.now()
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function(args)
      if vim.uv.now() - started < RESUME_GRACE then
        report.opened = report.opened - 1
        local why = last_line(args.buf) or ("conversation " .. tab.session_id:sub(1, 8) .. " exited straight away")
        not_reopened(report, tab, why)
      end
    end,
  })
  return true
end

-- Restoring is over: from here on the set is saved as it changes.
local function finish()
  restoring = false
  done = true
  if not ticker then
    ticker = vim.uv.new_timer()
    ticker:start(
      SAVE_EVERY,
      SAVE_EVERY,
      vim.schedule_wrap(function()
        local ft = package.loaded.floatterm
        if ft and #ft.tabs() > 0 then
          pcall(M.save, true)
        end
      end)
    )
  end
  pcall(M.save)
  pcall(prune)
end

-- Reopens `set`'s tabs. With `copy`, into a new set of this nvim's own (the set is
-- another running nvim's); otherwise this nvim takes the set over.
local function open_set(set, copy)
  local id = copy and new_id() or set.id
  if not take_lock(id) then
    vim.notify("floatterm: another nvim has just opened those tabs, so this one starts fresh", vim.log.levels.WARN)
    finish()
    return
  end
  current = id

  local report = new_report()
  local resumed = false
  if #set.tabs > 0 then
    -- claudecode.nvim loads lazily; it's loaded now so its port can be passed on.
    pcall(function()
      require("lazy").load { plugins = { "claudecode.nvim" } }
    end)
    for _, tab in ipairs(vim.deepcopy(set.tabs)) do
      if type(tab) == "table" then
        local ok, result = pcall(reopen, tab, report)
        if not ok then
          not_reopened(report, tab, (tostring(result):gsub("^.-:%d+: ", "")))
        elseif result then
          resumed = true
        end
      end
    end
  end

  -- Children whose parent didn't come back lose the link, and empty groups go.
  pcall(function()
    require("floatterm.groups").tidy()
  end)
  finish()
  if resumed then
    vim.defer_fn(function()
      notify(report)
    end, RESUME_GRACE + 500)
  else
    notify(report)
  end
end

-- "today 14:32", "28 Oct 09:10", or with the year when it isn't this one.
local function when(time)
  if os.date("%Y-%m-%d", time) == os.date "%Y-%m-%d" then
    return os.date("today %H:%M", time)
  end
  local day = tonumber(os.date("%d", time))
  if os.date("%Y", time) == os.date "%Y" then
    return day .. os.date(" %b %H:%M", time)
  end
  return day .. os.date(" %b %Y %H:%M", time)
end

-- A set's tabs on one line: ✳ for Claude, $ for a shell.
local function tab_list(set, width)
  local names = {}
  for _, tab in ipairs(set.tabs) do
    if type(tab) == "table" and tab.kind ~= "group" then
      table.insert(names, (tab.kind == "claude" and "✳ " or "$ ") .. name_of(tab))
    end
  end
  local text = table.concat(names, ", ")
  if width and vim.fn.strdisplaywidth(text) > width then
    text = vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text
end

-- The picker of saved sets. Calls on_choice(set), or on_choice(nil) to start fresh
-- (chosen, or the picker closed). A field so tests can stand in for it.
function M.pick(sets, on_choice)
  local ok = pcall(require, "telescope")
  if not ok then
    local items = vim.list_extend(vim.list_slice(sets), { "fresh" })
    vim.ui.select(items, {
      prompt = "Reopen which tabs?",
      format_item = function(item)
        return item == "fresh" and "Start fresh" or (when(item.saved_at) .. "  " .. tab_list(item, 70))
      end,
    }, function(choice)
      on_choice(choice ~= "fresh" and choice or nil)
    end)
    return
  end
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local entry_display = require "telescope.pickers.entry_display"

  local displayer = entry_display.create {
    separator = "  ",
    items = { { width = 13 }, { remaining = true } },
  }
  local entries = vim.list_extend(vim.list_slice(sets), { { fresh = true } })
  -- Whether the picker closed by a choice (or to delete), rather than Esc.
  local handled = false
  pickers
    .new({}, {
      prompt_title = "Reopen tabs in " .. vim.fn.fnamemodify(folder, ":t"),
      finder = finders.new_table {
        results = entries,
        entry_maker = function(set)
          if set.fresh then
            return { value = set, ordinal = "start fresh", display = "Start fresh" }
          end
          local list = tab_list(set)
          return {
            value = set,
            ordinal = list,
            display = function()
              return displayer { { when(set.saved_at), "Comment" }, tab_list(set, 90) }
            end,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      attach_mappings = function(prompt_buf, map)
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = prompt_buf,
          once = true,
          callback = function()
            vim.schedule(function()
              if not handled then
                on_choice(nil)
              end
            end)
          end,
        })
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          handled = true
          actions.close(prompt_buf)
          on_choice(entry and not entry.value.fresh and entry.value or nil)
        end)
        map({ "i", "n" }, "<C-d>", function()
          local entry = action_state.get_selected_entry()
          if not entry or entry.value.fresh then
            return
          end
          handled = true
          actions.close(prompt_buf)
          local set = entry.value
          local prompt = "Delete the tabs saved " .. when(set.saved_at) .. " (" .. tab_list(set, 50) .. ")?"
          vim.ui.select({ "Delete them", "Keep them" }, { prompt = prompt }, function(choice)
            if choice == "Delete them" then
              M.delete_set(set.id)
            end
            vim.schedule(function()
              local left = vim.tbl_filter(function(s)
                return s.id ~= set.id or choice ~= "Delete them"
              end, sets)
              if #left == 0 then
                on_choice(nil)
              else
                M.pick(left, on_choice)
              end
            end)
          end)
        end)
        return true
      end,
    })
    :find()
end

function M.restore()
  if done or restoring or not folder then
    return
  end
  if not M.allow_headless and #vim.api.nvim_list_uis() == 0 then
    return
  end
  -- Off means nothing at all: no saving, no sets, no questions.
  if not require("floatterm.settings").get "reopen_tabs" then
    return
  end
  restoring = true

  pcall(migrate)
  local sets = list_sets()
  local live, saved = {}, {}
  for _, set in ipairs(sets) do
    if #set.tabs > 0 then
      table.insert(set.live and live or saved, set)
    end
  end

  if #live > 0 then
    local items = {}
    for _, set in ipairs(live) do
      local which = #live > 1 and (" (" .. tab_list(set, 50) .. ")") or ""
      table.insert(items, {
        set = set,
        text = "Open the same tabs as the nvim already open here"
          .. which
          .. " (its Claude tabs resume the same conversations and share the same notes, so the two nvims' Claude tabs may clash: replies can interleave and either can lose its place)",
      })
    end
    table.insert(items, { text = "Start fresh" })
    vim.ui.select(items, {
      prompt = "Another nvim is open in " .. vim.fn.fnamemodify(folder, ":t"),
      format_item = function(item)
        return item.text
      end,
    }, function(choice)
      if choice and choice.set then
        open_set(choice.set, true)
      else
        finish()
      end
    end)
  elseif #saved == 1 then
    open_set(saved[1], false)
  elseif #saved > 1 then
    M.pick(saved, function(set)
      if set then
        open_set(set, false)
      else
        finish()
      end
    end)
  else
    finish()
  end
end

-- What this nvim's set is, for tests.
function M.state()
  return { folder = folder, dir = folder and folder_dir(), current = current, done = done }
end

-- Restores once nvim has started, saves as tabs change and on quit, and lets go of
-- the set. Call once at startup.
function M.setup()
  folder = started_folder()
  if not folder then
    return
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = { "FloatTermTabsChanged", "FloatTermTabChanged" },
    callback = save_soon,
  })
  vim.api.nvim_create_autocmd("FocusLost", {
    callback = function()
      pcall(M.save)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      pcall(M.save)
      release_lock()
    end,
  })
  if vim.v.vim_did_enter == 1 then
    M.restore()
  else
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = M.restore })
  end
end

return M
