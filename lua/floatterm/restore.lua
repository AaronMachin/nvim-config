-- Reopens the floating terminal's tabs when nvim starts again in the same folder.
--
-- With the reopen_tabs setting on, quitting an nvim started in a folder (no files
-- given) saves its tabs to stdpath("data")/floatterm-tabs/<folder>.json. Starting nvim
-- there again reopens them in the background, without showing the float:
--   Claude tabs resume their conversation (`claude --resume <id>`) where it ran. One
--   whose conversation was never written (Claude writes it after the first message)
--   starts a fresh `claude` in its folder instead.
--   Shell tabs are fresh shells in the same folder. What last ran in one is kept on
--   the record as last_command, but never run again.
-- A Claude tab that can't be reopened (its folder is gone, or its resume exits
-- straight away) is kept in the saved tabs and tried once more next time.
--
-- The first nvim to open a folder owns its saved tabs, through a .lock file beside
-- them holding its pid and server address. Another nvim in that folder, while the
-- owner runs, neither restores nor saves. Opening nvim on a file (as git's editor,
-- say) and nvim without a UI (headless) never do either.

local M = {}

-- Fields rather than locals so tests can point them somewhere else.
M.dir = vim.fn.stdpath "data" .. "/floatterm-tabs"
-- Lets headless nvim restore and save, for tests.
M.allow_headless = false

-- A resumed Claude that exits sooner than this didn't resume.
local RESUME_GRACE = 5000
-- How many times a tab that couldn't be reopened is tried before it's dropped.
local ATTEMPTS = 2

local folder = nil
local done = false
local restoring = false
local owner = false
-- Saved tabs that couldn't be reopened this time, written into the next save.
local carried = {}

local function file_for(dir)
  return M.dir .. "/" .. dir:gsub("/", "%%") .. ".json"
end

local function lock_file()
  return (file_for(folder):gsub("%.json$", ".lock"))
end

-- The folder nvim was started in, or nil when it was given files to open.
local function started_folder()
  local argc = vim.fn.argc()
  if argc == 0 then
    return vim.uv.fs_realpath(vim.uv.cwd())
  end
  if argc == 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
    return vim.uv.fs_realpath(vim.fn.argv(0))
  end
  return nil
end

-- Whether `pid` is a running nvim, so a lock left by one that crashed (or a pid since
-- reused by something else) doesn't count.
local function nvim_running(pid)
  local ok, found = pcall(vim.api.nvim_get_proc, pid)
  return ok and found ~= nil and (found.name or ""):match "nvim" ~= nil
end

-- Takes the folder's lock. Returns true, or false and the pid of the nvim holding it.
local function take_lock()
  vim.fn.mkdir(M.dir, "p")
  local path = lock_file()
  local mine = vim.json.encode { pid = vim.fn.getpid(), server = vim.v.servername }
  for _ = 1, 2 do
    -- Created only if it isn't there, so two nvims starting together can't both win.
    local fd = vim.uv.fs_open(path, "wx", 420)
    if fd then
      vim.uv.fs_write(fd, mine)
      vim.uv.fs_close(fd)
      return true
    end
    local file = io.open(path, "r")
    local ok, held = pcall(vim.json.decode, file and file:read "*a" or "")
    if file then
      file:close()
    end
    local pid = ok and type(held) == "table" and tonumber(held.pid) or nil
    if pid == vim.fn.getpid() then
      return true
    end
    if pid and nvim_running(pid) then
      return false, pid
    end
    os.remove(path)
  end
  return false, nil
end

local function release_lock()
  if not owner then
    return
  end
  local file = io.open(lock_file(), "r")
  if file then
    local ok, held = pcall(vim.json.decode, file:read "*a")
    file:close()
    if ok and type(held) == "table" and held.pid == vim.fn.getpid() then
      os.remove(lock_file())
    end
  end
  owner = false
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

function M.save()
  local settings = require "floatterm.settings"
  if not (folder and owner and done) or not settings.get "reopen_tabs" then
    return
  end
  if not package.loaded.floatterm and #carried == 0 then
    return
  end
  -- The tab bar only looks at what shells are running now and then.
  pcall(function()
    require("floatterm.tabbar").refresh_now()
  end)

  local saved = {}
  for _, record in ipairs(package.loaded.floatterm and require("floatterm").tabs() or {}) do
    local tab = {
      kind = record.kind,
      cwd = record.cwd,
      label = record.label,
      note_id = record.note_id,
      notes_on = record.notes_on,
    }
    if record.kind == "claude" then
      tab.session_id = record.session_id
      tab.transcript_path = record.transcript_path
      tab.start_ref = record.start_ref
      -- What the tab bar showed, so a resumed tab doesn't come back blank and "new".
      -- Working when nvim quit means stopped mid-way, which reads as done.
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
  vim.list_extend(saved, carried)

  local path = file_for(folder)
  if #saved == 0 then
    os.remove(path)
    return
  end
  vim.fn.mkdir(M.dir, "p")
  local file = io.open(path .. ".tmp", "w")
  if file then
    file:write(vim.json.encode(saved))
    file:close()
    os.rename(path .. ".tmp", path)
  end
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
end

local function notify(report)
  local parts = {}
  if #report.fresh > 0 then
    local several = #report.fresh > 1
    table.insert(
      parts,
      join(report.fresh) .. (several and " had no conversation yet, so they started fresh" or " had no conversation yet, so it started fresh")
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
  vim.notify("floatterm: reopened " .. opened .. "; " .. table.concat(parts, "; "), problem and vim.log.levels.WARN or nil)
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

local function reopen(tab, report)
  local floatterm = require "floatterm"
  if tab.kind ~= "claude" then
    local cwd = tab.cwd and vim.fn.isdirectory(tab.cwd) == 1 and tab.cwd or folder
    local _, buf = floatterm.new_tab(nil, { cwd = cwd, label = tab.label, show = false })
    floatterm.update(buf, {
      last_command = tab.last_command or vim.NIL,
      note_id = tab.note_id or vim.NIL,
      notes_on = tab.notes_on or vim.NIL,
    })
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
    floatterm.update(fresh, { note_id = tab.note_id or vim.NIL, notes_on = tab.notes_on or vim.NIL })
    report.opened = report.opened + 1
    table.insert(report.fresh, name_of(tab))
    return false
  end

  local buf = require("agent").open(tab.cwd, {
    argv = { "claude", "--resume", tab.session_id },
    label = tab.label,
    session_id = tab.session_id,
    start_ref = tab.start_ref,
    show = false,
  })
  floatterm.update(buf, {
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

function M.restore()
  local settings = require "floatterm.settings"
  if done or restoring or not folder then
    return
  end
  if not M.allow_headless and #vim.api.nvim_list_uis() == 0 then
    return
  end

  local held, other = take_lock()
  if not held then
    -- Only said when there's something it would have done.
    if settings.get "reopen_tabs" then
      vim.notify(
        "floatterm: " .. vim.fn.fnamemodify(folder, ":t") .. "'s tabs are open in another nvim"
          .. (other and (" (pid " .. other .. ")") or "") .. ", so this one won't reopen or save them",
        vim.log.levels.WARN
      )
    end
    return
  end
  owner = true

  if not settings.get "reopen_tabs" then
    done = true
    return
  end
  restoring = true

  local saved = nil
  local file = io.open(file_for(folder), "r")
  if file then
    local ok, decoded = pcall(vim.json.decode, file:read "*a", { luanil = { object = true } })
    file:close()
    saved = ok and type(decoded) == "table" and decoded or nil
  end

  local report = new_report()
  local resumed = false
  if saved and #saved > 0 then
    -- claudecode.nvim loads lazily; it's loaded now so its port can be passed on.
    pcall(function()
      require("lazy").load { plugins = { "claudecode.nvim" } }
    end)
    for _, tab in ipairs(saved) do
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

  restoring = false
  done = true
  if resumed then
    vim.defer_fn(function()
      notify(report)
    end, RESUME_GRACE + 500)
  else
    notify(report)
  end
end

-- Restores now (or once nvim has started), saves on quit and lets go of the folder.
-- Call once at startup.
function M.setup()
  folder = started_folder()
  if not folder then
    return
  end

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
