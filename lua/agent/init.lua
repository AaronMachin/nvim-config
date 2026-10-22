-- Claude Code sessions in floating-terminal tabs, one per git root (usually a worktree).
--
-- Each tab remembers the commit it started on, so everything Claude has changed since
-- can be reviewed in diffview. The tabs also back claudecode.nvim's terminal (see
-- M.provider), so :ClaudeCode and the IDE connection use them rather than a split.
--
-- Context (the selection, the quickfix list, the last test run) is pasted into the
-- "target" tab without pressing Enter, so there's room to add to it. The target is
-- the tab for the current file's git root, opened there if there isn't one. Only a
-- buffer outside any git root (the quickfix window, a scratch buffer) falls back to
-- the Claude tab focused last.

local M = {}

local api = vim.api

-- One entry per tab: { dir, buf, job, start_ref }.
local tabs = {}
-- When each tab's buffer was last entered, keyed by buffer, to find the most recent.
local entered = {}
local enter_count = 0

local PASTE_START, PASTE_END = "\27[200~", "\27[201~"

-- The directory with symlinks resolved and no trailing slash, so /tmp and
-- /private/tmp (or a path typed with a slash) find the same tab.
local function normalise(dir)
  dir = vim.fn.fnamemodify(dir, ":p")
  dir = vim.uv.fs_realpath(dir) or dir
  return (dir:gsub("(.)/$", "%1"))
end

local function git_root(path)
  local root = vim.fs.root(path, ".git")
  return root and normalise(root)
end

-- The current file's git root, or nil for a buffer that isn't a file in a repo.
local function buffer_root()
  local file = api.nvim_buf_get_name(0)
  if file ~= "" and vim.bo.buftype == "" then
    return git_root(file)
  end
  return nil
end

-- The current file's git root, else nvim's cwd's, else the cwd itself.
local function current_root()
  return buffer_root() or git_root(vim.uv.cwd()) or normalise(vim.uv.cwd())
end

local function find(dir)
  for _, tab in ipairs(tabs) do
    if tab.dir == dir then
      return tab
    end
  end
  return nil
end

local function touch(buf)
  enter_count = enter_count + 1
  entered[buf] = enter_count
end

local function most_recent()
  local best = nil
  for _, tab in ipairs(tabs) do
    if not best or (entered[tab.buf] or 0) > (entered[best.buf] or 0) then
      best = tab
    end
  end
  return best
end

local function forget(buf)
  for i, tab in ipairs(tabs) do
    if tab.buf == buf then
      table.remove(tabs, i)
      break
    end
  end
  entered[buf] = nil
end

-- The variables claudecode.nvim gives its own terminal, so a tab opened here (not
-- through :ClaudeCode) still connects back to nvim. Empty when the plugin isn't running.
local function ide_env()
  local ok, server = pcall(require, "claudecode.server.init")
  if not (ok and server.state and server.state.port) then
    return nil
  end
  return {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
    CLAUDE_CODE_SSE_PORT = tostring(server.state.port),
  }
end

-- Opens a Claude tab in `dir`. opts: label, argv (claude by default) and env.
local function open(dir, opts)
  opts = opts or {}
  local start = vim.system({ "git", "rev-parse", "HEAD" }, { cwd = dir, text = true }):wait()
  local start_ref = start.code == 0 and vim.trim(start.stdout) or nil

  local job, buf = require("floatterm").new_tab(opts.argv or { "claude" }, {
    cwd = dir,
    env = opts.env or ide_env(),
    label = opts.label or vim.fn.fnamemodify(dir, ":t"),
  })
  table.insert(tabs, { dir = dir, buf = buf, job = job, start_ref = start_ref })
  touch(buf)

  api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      touch(buf)
    end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      forget(buf)
    end,
  })
  return buf
end

-- Focuses the Claude tab for `dir`, or opens one. opts.label overrides the tab's
-- name (the folder's). Returns the tab's buffer.
function M.start(dir, opts)
  dir = normalise(dir)
  local tab = find(dir)
  if tab then
    require("floatterm").focus_buf(tab.buf)
    touch(tab.buf)
    return tab.buf
  end
  return open(dir, opts)
end

function M.tab_for(dir)
  local tab = find(normalise(dir))
  return tab and tab.buf
end

function M.list()
  return tabs
end

-- The tab context goes to, whether it was just opened, and the folder it was looked
-- for in. A file in a repo only ever gets its own root's tab (opened with `create`),
-- never another worktree's. Any other buffer gets the tab focused last, with
-- `fallback` set so the caller can say where it went, or with `create` and no tabs
-- at all, a new one for nvim's cwd.
local function target(create)
  local root = buffer_root()
  local tab = root and find(root)
  if tab or (root and not create) then
    return tab, false, root
  end
  if not root then
    local recent = most_recent()
    if recent then
      return recent, false, recent.dir, true
    end
    if not create then
      return nil, false, nil
    end
    root = current_root()
  end
  open(root)
  return find(root), true, root
end

-- Waits until Claude has drawn something in a new tab (or a few seconds pass), then a
-- little longer for its prompt to take input, before `fn` runs.
local function when_ready(tab, fn)
  local waited = 0
  local timer = vim.uv.new_timer()
  timer:start(200, 200, vim.schedule_wrap(function()
    waited = waited + 200
    local drawn = api.nvim_buf_is_valid(tab.buf)
      and #vim.trim(table.concat(api.nvim_buf_get_lines(tab.buf, 0, -1, false), "")) > 0
    if drawn or waited >= 8000 then
      timer:stop()
      timer:close()
      vim.defer_fn(fn, 1000)
    end
  end))
end

-- Pastes `text` into the target tab without submitting it, then shows the tab.
-- `build` takes the tab's directory and returns the text, so paths can be relative to it.
local function paste(build)
  local tab, is_new, _, fallback = target(true)
  if not tab then
    vim.notify("agent: couldn't start Claude", vim.log.levels.WARN)
    return
  end
  if fallback then
    vim.notify("agent: this buffer isn't in a git repository, so it went to the Claude tab in " .. vim.fn.fnamemodify(tab.dir, ":t"))
  end
  local text = build(tab.dir)

  local function send()
    if not api.nvim_buf_is_valid(tab.buf) then
      return
    end
    api.nvim_chan_send(tab.job, PASTE_START .. text .. PASTE_END)
    require("floatterm").focus_buf(tab.buf)
  end

  if is_new then
    when_ready(tab, send)
  else
    send()
  end
end

-- `path` relative to `dir` when it's inside it, else as it is.
local function relative(path, dir)
  path = normalise(path)
  if path:sub(1, #dir + 1) == dir .. "/" then
    return path:sub(#dir + 2)
  end
  return path
end

local function in_visual()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22"
end

local function leave_visual()
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
end

-- Sends `@path#L12-30 ` for the selected lines, or `@path ` for the file in normal mode.
function M.send_selection()
  local file = api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    vim.notify("agent: not a file", vim.log.levels.WARN)
    return
  end

  local range = ""
  if in_visual() then
    local first, last = vim.fn.line "v", vim.fn.line "."
    if first > last then
      first, last = last, first
    end
    range = first == last and ("#L" .. first) or ("#L" .. first .. "-" .. last)
    leave_visual()
  end

  paste(function(dir)
    return "@" .. relative(file, dir) .. range .. " "
  end)
end

function M.send_quickfix()
  local items = vim.fn.getqflist()
  if #items == 0 then
    vim.notify("agent: the quickfix list is empty", vim.log.levels.WARN)
    return
  end

  paste(function(dir)
    local lines = { "Fix these:" }
    for _, item in ipairs(items) do
      local name = item.bufnr > 0 and api.nvim_buf_get_name(item.bufnr) or ""
      local where = name ~= "" and (relative(name, dir) .. ":" .. item.lnum .. ": ") or ""
      table.insert(lines, where .. vim.trim(item.text))
    end
    return table.concat(lines, "\n") .. "\n"
  end)
end

function M.send_last_test()
  local testrun = require "testrun"
  local output = testrun.last_output()
  if not output then
    vim.notify("agent: no test output (no run yet, or its tab was closed)", vim.log.levels.WARN)
    return
  end

  paste(function()
    return "This test run failed: " .. testrun.last_command() .. "\n\n" .. table.concat(output, "\n") .. "\n"
  end)
end

-- A centred markdown float showing `lines`. q or Esc closes it, calling on_close.
local function answer_window(lines, on_close)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, vim.o.columns - 8)
  local height = math.min(30, vim.o.lines - 6)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = " Claude ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    if on_close then
      on_close()
    end
  end
  for _, key in ipairs { "q", "<Esc>" } do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true })
  end
  return buf
end

-- Asks `claude -p` the prompt (with `input` on stdin, if any) and calls done(text,
-- error) on the main loop. Returns the process, so it can be stopped.
local function ask(prompt, input, cwd, done)
  return vim.system({ "claude", "-p", prompt }, { cwd = cwd, stdin = input, text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        done(vim.trim(result.stdout), nil)
      else
        done(nil, vim.trim(result.stderr ~= "" and result.stderr or result.stdout))
      end
    end)
  end)
end

-- Explains the selected code in a float, without going through a session.
function M.explain()
  if not in_visual() then
    vim.notify("agent: select some code first", vim.log.levels.WARN)
    return
  end

  local text = table.concat(vim.fn.getregion(vim.fn.getpos "v", vim.fn.getpos ".", { type = vim.fn.mode() }), "\n")
  leave_visual()
  local file = api.nvim_buf_get_name(0)
  local root = current_root()
  local prompt = "Briefly explain what this code from "
    .. (file ~= "" and relative(file, root) or "an unsaved buffer")
    .. " ("
    .. (vim.bo.filetype ~= "" and vim.bo.filetype or "unknown filetype")
    .. ") does, in a few short paragraphs of markdown. Don't restate the code."

  local process
  local buf = answer_window({ "Asking Claude…" }, function()
    if process and not process:is_closing() then
      process:kill "sigterm"
    end
  end)
  process = ask(prompt, text, root, function(answer, err)
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(answer or ("Claude failed: " .. err), "\n"))
    end
  end)
end

-- Opens diffview with everything since the target tab's Claude started (commits and
-- uncommitted changes), or closes diffview if it's open.
function M.review()
  if require("diffview.lib").get_current_view() then
    vim.cmd "DiffviewClose"
    return
  end

  -- A tab opened now would have nothing to review, so none is started.
  local tab, _, dir, fallback = target(false)
  if not tab then
    local where = dir and (" in " .. vim.fn.fnamemodify(dir, ":t")) or ""
    vim.notify("agent: no Claude tab" .. where .. " to review", vim.log.levels.WARN)
    return
  end
  if fallback then
    vim.notify("agent: this buffer isn't in a git repository, so reviewing the Claude tab in " .. vim.fn.fnamemodify(tab.dir, ":t"))
  end
  if not tab.start_ref then
    vim.notify("agent: " .. tab.dir .. " had no commit when Claude started", vim.log.levels.WARN)
    return
  end

  require("floatterm").hide()
  vim.cmd("DiffviewOpen " .. tab.start_ref .. " -C" .. vim.fn.fnameescape(tab.dir))
end

local function git(args, root)
  return vim.system(vim.list_extend({ "git" }, args), { cwd = root, text = true }):wait()
end

-- Claude sometimes wraps the message in a code fence anyway.
local function strip_fence(text)
  local lines = vim.split(text, "\n")
  if lines[1] and lines[1]:match "^```" then
    table.remove(lines, 1)
    if lines[#lines] and lines[#lines]:match "^```" then
      table.remove(lines)
    end
  end
  return lines
end

-- Asks Claude for a commit message for what's staged, in a gitcommit split. :w commits.
function M.commit_message()
  local file = api.nvim_buf_get_name(0)
  local root = (file ~= "" and vim.bo.buftype == "" and git_root(file)) or git_root(vim.uv.cwd())
  if not root then
    vim.notify("agent: not in a git repository", vim.log.levels.WARN)
    return
  end
  if git({ "diff", "--cached", "--quiet" }, root).code == 0 then
    vim.notify("agent: nothing is staged", vim.log.levels.WARN)
    return
  end

  local diff = git({ "diff", "--cached" }, root).stdout
  local subjects = vim.trim(git({ "log", "-15", "--format=%s" }, root).stdout)
  local branch = vim.trim(git({ "branch", "--show-current" }, root).stdout)
  local ticket = branch:match "^(%u+%-%d+)"

  local prompt = "Write a git commit message for the staged diff on stdin. Match the style of these recent subjects:\n\n"
    .. subjects
    .. "\n\n"
    .. (ticket and ("Start the subject with the ticket key " .. ticket .. ", as those subjects do with theirs. ") or "")
    .. "Add a short body only if the change needs explaining. No Co-Authored-By or other trailers. "
    .. "Output only the message, with no code fence or commentary."

  vim.cmd "botright new"
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_name(buf, "agent://commit-message/" .. buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "gitcommit"
  api.nvim_buf_set_lines(buf, 0, -1, false, { "Asking Claude…" })
  -- Unmodified only while it holds the placeholder, so it can be closed without a fuss.
  vim.bo[buf].modified = false
  local placeholder_tick = api.nvim_buf_get_changedtick(buf)
  local asking, committing, committed = true, false, false

  -- A draft with changes is hidden rather than wiped when its window closes, so a
  -- stray :q doesn't lose it (it stays in the buffer list). BufModifiedSet only
  -- follows typing, so filling it below sets this too.
  api.nvim_create_autocmd("BufModifiedSet", {
    buffer = buf,
    callback = function()
      vim.bo[buf].bufhidden = vim.bo[buf].modified and "hide" or "wipe"
    end,
  })

  ask(prompt, diff, root, function(message, err)
    asking = false
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].bufhidden = "hide"
    local lines = message and strip_fence(message) or { "", "# Claude failed: " .. err }
    if api.nvim_buf_get_changedtick(buf) ~= placeholder_tick then
      -- Typed in while Claude was thinking: theirs stays, Claude's goes below as
      -- comments, which the commit strips.
      local suggestion = { "", "# Claude's suggestion, not used because you'd started typing:" }
      for _, line in ipairs(lines) do
        table.insert(suggestion, line:match "^#" and line or ("# " .. line))
      end
      api.nvim_buf_set_lines(buf, -1, -1, false, suggestion)
      vim.notify("agent: you'd typed in the message, so Claude's suggestion is added below it as comments")
      return
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end)

  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if committed or committing then
        return
      end
      if asking and api.nvim_buf_get_changedtick(buf) == placeholder_tick then
        vim.notify("agent: Claude is still writing the message", vim.log.levels.WARN)
        return
      end
      -- The message describes the diff it was written from, so it isn't used for another.
      if git({ "diff", "--cached" }, root).stdout ~= diff then
        vim.notify(
          "agent: the staged changes changed since the message was written, so nothing was committed",
          vim.log.levels.ERROR
        )
        return
      end

      committing = true
      local path = vim.fn.tempname()
      vim.fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), path)
      -- --cleanup=strip drops # lines, and git refuses a message that ends up empty.
      vim.system({ "git", "commit", "--cleanup=strip", "-F", path }, { cwd = root, text = true }, function(result)
        vim.schedule(function()
          os.remove(path)
          committing = false
          if result.code ~= 0 then
            vim.notify("agent: " .. vim.trim(result.stderr ~= "" and result.stderr or result.stdout), vim.log.levels.ERROR)
            return
          end
          committed = true
          vim.notify(vim.split(vim.trim(result.stdout), "\n")[1])
          if api.nvim_buf_is_valid(buf) then
            vim.bo[buf].modified = false
            api.nvim_buf_delete(buf, { force = true })
          end
        end)
      end)
    end,
  })
end

-- claudecode.nvim's terminal, as a Claude tab for the git root of nvim's cwd. Its
-- env_table carries the port Claude connects back on.
local function cwd_dir(config)
  local dir = config and config.cwd
  return dir and normalise(dir) or git_root(vim.uv.cwd()) or normalise(vim.uv.cwd())
end

local function provider_open(cmd_string, env_table, config, focus)
  local dir = cwd_dir(config)
  local tab = find(dir)
  if tab then
    if focus ~= false then
      M.start(dir)
    end
    return
  end

  local previous = api.nvim_get_current_win()
  -- exec so :ClaudeCode's arguments (--resume, say) are split as the shell would.
  open(dir, { argv = { vim.o.shell, "-c", "exec " .. cmd_string }, env = env_table })
  if focus == false then
    require("floatterm").hide()
    if api.nvim_win_is_valid(previous) then
      api.nvim_set_current_win(previous)
    end
    vim.cmd "stopinsert"
  end
end

local function provider_toggle(cmd_string, env_table, config)
  local tab = find(cwd_dir(config))
  if tab and require("floatterm").is_showing(tab.buf) then
    require("floatterm").hide()
  else
    provider_open(cmd_string, env_table, config, true)
  end
end

M.provider = {
  setup = function() end,
  open = provider_open,
  close = function()
    local tab = find(cwd_dir())
    if tab then
      vim.fn.jobstop(tab.job)
    end
  end,
  simple_toggle = provider_toggle,
  -- The float always takes focus when shown, so focusing and showing are the same.
  focus_toggle = provider_toggle,
  get_active_bufnr = function()
    local tab = find(cwd_dir()) or most_recent()
    return tab and tab.buf
  end,
  is_available = function()
    return true
  end,
}

-- A proposed edit opens as a diff in the editor, which the float would cover.
api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeDiffOpened",
  callback = function()
    require("floatterm").hide()
  end,
})

return M
