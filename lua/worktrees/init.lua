-- Git worktrees: a picker, creating one for a ticket, and moving nvim between them.
--
-- The repo's first worktree is the main checkout (the one Sail runs from); the rest
-- sit beside it as <main>-<ticket>-<name>. Moving nvim to another worktree saves a
-- session for the one it leaves, closes its file buffers and restores the other's
-- session, if it has one. Terminal tabs (Claude, shells) are never touched, so they
-- keep running across the move. Nothing restores a session on startup.

local M = {}

-- A field rather than a local so tests can point it somewhere other than the live sessions.
M.sessions_dir = vim.fn.stdpath "data" .. "/sessions"

local HINTS = "Enter move nvim · C-a Claude · C-s main checks out its branch"
local MARKS = "⌂ main · ● nvim here · ✳ Claude tab"

local function notify(message, level)
  vim.notify("worktrees: " .. message, level or vim.log.levels.INFO)
end

local function realpath(path)
  return path and (vim.uv.fs_realpath(path) or vim.fs.normalize(path)) or nil
end

local function git(dir, args)
  local result = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

-- The worktree nvim's cwd is in, or nil outside git. `.git` is a file in a
-- worktree, which vim.fs.root matches as well as a directory.
local function current_root()
  return realpath(vim.fs.root(vim.uv.cwd(), ".git"))
end

-- The repo's worktrees from `git worktree list --porcelain`, main checkout first.
local function worktrees(cwd)
  local ok, out, err = git(cwd or vim.uv.cwd(), { "worktree", "list", "--porcelain" })
  if not ok then
    return nil, err ~= "" and err or "not in a git repository"
  end

  local list, item = {}, nil
  for line in (out .. "\n"):gmatch "(.-)\n" do
    local key, value = line:match "^(%S+)%s?(.*)$"
    if key == "worktree" then
      item = { dir = value, name = vim.fs.basename(value) }
      table.insert(list, item)
    elseif item and key == "HEAD" then
      item.head = value
    elseif item and key == "branch" then
      item.branch = value:gsub("^refs/heads/", "")
    elseif item and key == "detached" then
      item.detached = true
    elseif item and key == "bare" then
      item.bare = true
    elseif item and key == "prunable" then
      item.missing = true
    end
  end

  list = vim.tbl_filter(function(wt)
    return not wt.bare
  end, list)
  if list[1] then
    list[1].is_main = true
  end
  return list
end

local function find_worktree(list, dir)
  dir = realpath(dir)
  for _, wt in ipairs(list) do
    if realpath(wt.dir) == dir then
      return wt
    end
  end
  return nil
end

local function agent_tab(dir)
  local ok, agent = pcall(require, "agent")
  if not (ok and type(agent.tab_for) == "function") then
    return nil
  end
  local found, buf = pcall(agent.tab_for, dir)
  return found and buf or nil
end

-- "3m", "5h", "2d", "6w", "4mo".
local function age(seconds)
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return math.max(minutes, 0) .. "m"
  elseif minutes < 60 * 24 then
    return math.floor(minutes / 60) .. "h"
  elseif minutes < 60 * 24 * 14 then
    return math.floor(minutes / (60 * 24)) .. "d"
  elseif minutes < 60 * 24 * 60 then
    return math.floor(minutes / (60 * 24 * 7)) .. "w"
  end
  return math.floor(minutes / (60 * 24 * 30)) .. "mo"
end

-- Counts each worktree's uncommitted files, every one in parallel, from one shell.
-- Starting a process from nvim costs about 13ms here, so one shell that starts the
-- 18 git calls itself opens the picker far sooner than 18 calls from nvim would.
-- Prints "<count or x>\t<dir>" per worktree.
local COUNT_SCRIPT = [[
for dir in "$@"; do
  (
    if out=$(git --no-optional-locks -C "$dir" status --porcelain 2>/dev/null); then
      printf '%s\t%s\n' "$(printf '%s' "$out" | grep -c '')" "$dir"
    else
      printf 'x\t%s\n' "$dir"
    fi
  ) &
done
wait
]]

-- Every worktree with its last commit and, once status has run in each, its count
-- of uncommitted files. The last commits come from one `git log` over every HEAD.
-- With `on_status`, list returns straight away and on_status(list) is called once
-- the counts are in; without it, list waits for them. --no-optional-locks stops
-- status refreshing the index, so it never trips up git running in an agent's worktree.
function M.list(cwd, on_status)
  local list, err = worktrees(cwd)
  if not list then
    return nil, err
  end

  local by_dir, dirs = {}, {}
  for _, wt in ipairs(list) do
    if not wt.missing then
      by_dir[wt.dir] = wt
      table.insert(dirs, wt.dir)
    end
  end
  local job = vim.system(vim.list_extend({ "sh", "-c", COUNT_SCRIPT, "sh" }, dirs), { text = true }, function(result)
    for line in (result.stdout or ""):gmatch "[^\n]+" do
      local count, dir = line:match "^(%S+)\t(.*)$"
      if by_dir[dir] then
        -- -1: status failed there, shown as "?".
        by_dir[dir].changes = tonumber(count) or -1
      end
    end
    if on_status then
      vim.schedule(function()
        on_status(list)
      end)
    end
  end)

  local heads = vim.tbl_map(function(wt)
    return wt.head
  end, vim.tbl_filter(function(wt)
    return wt.head and not wt.missing
  end, list))
  local commits = {}
  if #heads > 0 then
    local _, out = git(list[1].dir, vim.list_extend({ "log", "--no-walk=unsorted", "--format=%H%x09%ct%x09%s" }, heads))
    for line in out:gmatch "[^\n]+" do
      local sha, time, subject = line:match "^(%x+)\t(%d+)\t(.*)$"
      if sha then
        commits[sha] = { time = tonumber(time), subject = subject }
      end
    end
  end

  local here = current_root()
  local now = os.time()
  for _, wt in ipairs(list) do
    wt.is_current = here ~= nil and realpath(wt.dir) == here
    wt.agent_buf = agent_tab(wt.dir)
    local commit = commits[wt.head or ""]
    wt.age = commit and age(now - commit.time) or ""
    wt.subject = commit and commit.subject or ""
  end

  if not on_status then
    job:wait()
  end
  return list
end

-- Sessions ------------------------------------------------------------------

function M.session_path(dir)
  return M.sessions_dir .. "/" .. realpath(dir):gsub("/", "%%") .. ".vim"
end

local function file_buffers()
  return vim.tbl_filter(function(buf)
    return vim.bo[buf].buftype == "" and vim.bo[buf].buflisted
  end, vim.api.nvim_list_bufs())
end

-- Saves a session for `dir`, unless no file is open: a worktree left with nothing
-- open keeps the session it had, so opening nvim and quitting straight away doesn't
-- wipe it. Floats (the terminal, pickers) are never part of a session.
function M.save_session(dir)
  local named = vim.tbl_filter(function(buf)
    return vim.api.nvim_buf_get_name(buf) ~= ""
  end, file_buffers())
  if not dir or #named == 0 then
    return false
  end

  vim.fn.mkdir(M.sessions_dir, "p")
  local saved = vim.o.sessionoptions
  local options = vim.tbl_filter(function(option)
    return not vim.tbl_contains({ "terminal", "blank", "help", "options" }, option)
  end, vim.split(saved, ","))
  vim.o.sessionoptions = table.concat(options, ",")
  local ok, err = pcall(vim.cmd, "mksession! " .. vim.fn.fnameescape(M.session_path(dir)))
  vim.o.sessionoptions = saved
  if not ok then
    notify("could not save the session: " .. err, vim.log.levels.WARN)
  end
  return ok
end

-- Leaves one empty window and no file buffers. Windows are closed rather than their
-- buffers deleted one by one, which would leave a split layout behind for a worktree
-- with no session. Terminal buffers are only hidden by this, so their jobs keep running.
local function close_file_buffers()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative == "" and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
  vim.cmd "silent! tabonly | silent! only | enew"

  local fresh = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(file_buffers()) do
    if buf ~= fresh then
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
  end
end

-- Moves nvim to the worktree at `dir`. Refuses, saying which, while a file buffer has
-- unsaved changes.
function M.switch(dir)
  dir = realpath(dir)
  local here = current_root()
  if dir == here then
    notify("nvim is already in " .. vim.fs.basename(dir))
    return false
  end

  local modified = {}
  for _, buf in ipairs(file_buffers()) do
    if vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      table.insert(modified, name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":~:."))
    end
  end
  if #modified > 0 then
    notify("save or discard these first: " .. table.concat(modified, ", "), vim.log.levels.WARN)
    return false
  end

  local has_floatterm, floatterm = pcall(require, "floatterm")
  if has_floatterm then
    floatterm.hide()
  end
  M.save_session(here)
  close_file_buffers()
  vim.cmd("cd " .. vim.fn.fnameescape(dir))

  local session = M.session_path(dir)
  local restored = false
  if vim.uv.fs_stat(session) then
    local ok, err = pcall(vim.cmd, "silent source " .. vim.fn.fnameescape(session))
    if not ok then
      notify("could not restore the session: " .. err, vim.log.levels.WARN)
    end
    restored = ok
  end

  notify("nvim is now in " .. vim.fs.basename(dir) .. (restored and " (session restored)" or ""))
  return true
end

-- Async flows ---------------------------------------------------------------
-- create and switch_main read as straight lines: each await gives up the coroutine
-- until a callback resumes it. Callbacks are scheduled so a stub that answers at
-- once (as tests do) still resumes after the yield.

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
  end
end

local function run_async(fn)
  resume(coroutine.create(fn))
end

local function await(start)
  local co = coroutine.running()
  start(function(...)
    local args = { ... }
    vim.schedule(function()
      resume(co, unpack(args))
    end)
  end)
  return coroutine.yield()
end

local function await_git(dir, args)
  local result = await(function(done)
    vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }, done)
  end)
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

local function await_select(items, prompt)
  return await(function(done)
    vim.ui.select(items, { prompt = prompt }, done)
  end)
end

local function await_input(prompt)
  return await(function(done)
    vim.ui.input({ prompt = prompt }, done)
  end)
end

local function start_agent(dir)
  local ok, agent = pcall(require, "agent")
  if not (ok and type(agent.start) == "function") then
    notify("the agent module isn't available", vim.log.levels.WARN)
    return
  end
  agent.start(dir)
end

-- Create --------------------------------------------------------------------

-- The remote's default branch (origin/HEAD), falling back to origin/main.
local function default_base(main)
  local ok, out = git(main, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  return ok and out ~= "" and out or "origin/main"
end

-- Asks for a ticket key and a short name, then makes branch SD-501-backend in
-- <main>-sd-501-backend from the freshly fetched default branch.
function M.create()
  run_async(function()
    local list, err = worktrees()
    if not list then
      notify(err, vim.log.levels.WARN)
      return
    end
    local main = list[1].dir

    local key = await_input "Ticket key (e.g. SD-501, may be empty): "
    if key == nil then
      return
    end
    local name = await_input "Short name (e.g. backend): "
    if name == nil then
      return
    end
    key, name = vim.trim(key):upper(), vim.trim(name)
    if name == "" then
      notify("a short name is needed", vim.log.levels.WARN)
      return
    end

    local branch = key ~= "" and (key .. "-" .. name) or name
    local folder = vim.fs.dirname(main) .. "/" .. vim.fs.basename(main) .. "-" .. branch:lower()

    if not git(main, { "check-ref-format", "--branch", branch }) or branch:find "%s" then
      notify(branch .. " isn't a valid branch name", vim.log.levels.WARN)
      return
    end
    if git(main, { "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }) then
      notify("branch " .. branch .. " already exists", vim.log.levels.WARN)
      return
    end
    if vim.uv.fs_stat(folder) then
      notify(vim.fn.fnamemodify(folder, ":~") .. " already exists", vim.log.levels.WARN)
      return
    end

    local base = default_base(main)
    local remote, remote_branch = base:match "^([^/]+)/(.+)$"
    notify("fetching " .. base .. "...")
    local fetched, _, fetch_err = await_git(main, { "fetch", remote, remote_branch })
    -- Offline, the worktree is still made, from the base as last fetched.
    if not fetched then
      notify("couldn't fetch " .. base .. ", using it as last fetched: " .. fetch_err, vim.log.levels.WARN)
    end

    local added, _, add_err = await_git(main, { "worktree", "add", "-b", branch, folder, base })
    if not added then
      notify("git worktree add failed: " .. add_err, vim.log.levels.ERROR)
      return
    end

    notify(
      "created "
        .. branch
        .. " in "
        .. vim.fs.basename(folder)
        .. " from "
        .. base
        .. ". It has no vendor/ or node_modules yet, so install those before running anything"
    )

    -- Both are asked first, so the agent's tab opens after nvim has moved and stays in view.
    local agent = await_select({ "Yes", "No" }, "Start a Claude agent in " .. vim.fs.basename(folder) .. "?")
    local move = await_select({ "Yes", "No" }, "Move nvim to " .. vim.fs.basename(folder) .. "?")
    if move == "Yes" then
      M.switch(folder)
    end
    if agent == "Yes" then
      start_agent(folder)
    end
  end)
end

-- Switch the main checkout --------------------------------------------------

-- Checks out the branch of the worktree at `dir` in the main checkout, so Sail runs
-- it. git won't check out a branch another worktree holds, so that worktree is
-- detached first (its files stay as they are), and main's own changes are stashed.
function M.switch_main(dir)
  run_async(function()
    local list, err = worktrees()
    if not list then
      notify(err, vim.log.levels.WARN)
      return
    end
    local main, wt = list[1], find_worktree(list, dir)
    if not wt then
      notify(dir .. " isn't a worktree of this repo", vim.log.levels.WARN)
      return
    end
    if wt.is_main then
      notify("that is the main checkout", vim.log.levels.WARN)
      return
    end
    if not wt.branch then
      notify(wt.name .. " is detached, so there's no branch to check out", vim.log.levels.WARN)
      return
    end

    local ok, status, status_err = git(main.dir, { "--no-optional-locks", "status", "--porcelain" })
    if not ok then
      notify("couldn't read main's status: " .. status_err, vim.log.levels.ERROR)
      return
    end
    local changes = #vim.split(status, "\n", { trimempty = true })
    local plural = changes == 1 and "" or "s"

    local plan = string.format(
      "main: %scheck out %s; %s: detach HEAD (its files stay as they are)",
      changes > 0 and string.format("stash %d uncommitted file%s, then ", changes, plural) or "",
      wt.branch,
      wt.name
    )
    if await_select({ "Go ahead", "Cancel" }, plan) ~= "Go ahead" then
      return
    end

    local done = {}
    local function fail(step, message)
      -- git's first line says what went wrong; the rest is advice.
      message = vim.split(message, "\n")[1]:gsub("%.$", "")
      local so_far = #done > 0 and (" Already done: " .. table.concat(done, "; ") .. ".") or ""
      notify(step .. " failed, stopped there: " .. message .. "." .. so_far, vim.log.levels.ERROR)
    end

    if changes > 0 then
      local message = "worktrees: before switching to " .. wt.branch
      local stashed, _, stash_err = await_git(main.dir, { "stash", "push", "-u", "-m", message })
      if not stashed then
        return fail("stashing main's changes", stash_err)
      end
      table.insert(done, string.format('stashed %d file%s in main as "%s"', changes, plural, message))
    end

    local detached, _, detach_err = await_git(wt.dir, { "switch", "--detach" })
    if not detached then
      return fail("detaching " .. wt.name, detach_err)
    end
    table.insert(done, "detached " .. wt.name)

    local switched, _, switch_err = await_git(main.dir, { "switch", wt.branch })
    if not switched then
      return fail("checking out " .. wt.branch .. " in main", switch_err)
    end
    table.insert(done, "main is on " .. wt.branch)

    -- Buffers open from main now have different files under them.
    vim.cmd "silent! checktime"
    notify(table.concat(done, "; "))
  end)
end

-- Picker --------------------------------------------------------------------

-- Fills the preview once git is back, so moving through the list never waits on
-- it. Each entry gets its own preview buffer, so a late answer for an entry already
-- moved past lands in a buffer nobody is looking at.
local function preview(self, entry)
  local buf = self.state.bufnr
  local script = 'git --no-optional-locks -C "$1" status -sb; echo; git -C "$1" log --oneline -10'
  vim.system({ "sh", "-c", script, "sh", entry.value.dir }, { text = true }, function(result)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.trim(result.stdout or ""), "\n"))
      end
    end)
  end)
end

function M.pick()
  local picker, refresh_counts
  local list, err = M.list(nil, function()
    if refresh_counts then
      refresh_counts()
    end
  end)
  if not list then
    notify(err, vim.log.levels.WARN)
    return
  end

  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local previewers = require "telescope.previewers"
  local entry_display = require "telescope.pickers.entry_display"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"

  local name_width, branch_width = 4, 8
  for _, wt in ipairs(list) do
    name_width = math.max(name_width, #wt.name)
    branch_width = math.max(branch_width, #(wt.branch or "detached"))
  end

  local displayer = entry_display.create {
    separator = " ",
    items = {
      { width = 1 },
      { width = 1 },
      { width = 1 },
      { width = math.min(name_width, 44) },
      { width = math.min(branch_width, 36) },
      { width = 4, right_justify = true },
      { width = 4, right_justify = true },
      { remaining = true },
    },
  }

  local function display(entry)
    local wt = entry.value
    local changes = ""
    if wt.missing then
      changes = "gone"
    elseif wt.changes == nil then
      changes = "…"
    elseif wt.changes < 0 then
      changes = "?"
    elseif wt.changes > 0 then
      changes = "±" .. wt.changes
    end
    return displayer {
      { wt.is_main and "⌂" or " ", "Special" },
      { wt.is_current and "●" or " ", "DiagnosticOk" },
      { wt.agent_buf and "✳" or " ", "DiagnosticInfo" },
      wt.name,
      { wt.branch or "detached", wt.branch and "Identifier" or "Comment" },
      { changes, "DiagnosticWarn" },
      { wt.age or "", "Comment" },
      wt.subject or "",
    }
  end

  local function with_selection(prompt_bufnr, fn)
    return function()
      local entry = action_state.get_selected_entry()
      actions.close(prompt_bufnr)
      if entry then
        vim.schedule(function()
          fn(entry.value.dir)
        end)
      end
    end
  end

  local function finder()
    return finders.new_table {
      results = list,
      entry_maker = function(wt)
        return {
          value = wt,
          display = display,
          ordinal = table.concat({ wt.name, wt.branch or "detached", wt.subject or "" }, " "),
        }
      end,
    }
  end

  picker = pickers.new({}, {
    prompt_title = "Worktrees  " .. MARKS,
    preview_title = HINTS,
    finder = finder(),
    sorter = conf.generic_sorter {},
    previewer = previewers.new_buffer_previewer {
      title = HINTS,
      define_preview = preview,
    },
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(with_selection(prompt_bufnr, M.switch))
      map({ "i", "n" }, "<C-a>", with_selection(prompt_bufnr, start_agent), { desc = "worktrees start or focus Claude" })
      map({ "i", "n" }, "<C-s>", with_selection(prompt_bufnr, M.switch_main), { desc = "worktrees main checks out its branch" })
      return true
    end,
  })

  -- The counts arrive after the picker opens. Refreshing redraws the rows but moves
  -- the selection to the top, so it's put back on the worktree that was selected.
  refresh_counts = function()
    if not vim.api.nvim_buf_is_valid(picker.prompt_bufnr or -1) then
      return
    end
    local selected = picker:get_selection()
    local dir = selected and selected.value.dir
    local restored = false
    picker:register_completion_callback(function()
      if restored or not dir then
        return
      end
      restored = true
      for index = 1, picker.manager:num_results() do
        if picker.manager:get_entry(index).value.dir == dir then
          picker:set_selection(picker:get_row(index))
          break
        end
      end
    end)
    picker:refresh(finder(), { reset_prompt = false })
  end

  picker:find()
end

-- Setup ---------------------------------------------------------------------

-- Saves the session for nvim's worktree on quit. Not when nvim was opened on
-- particular files (a commit message from git or lazygit, say): that's not the
-- session you were working in, and saving it would replace the one that is.
function M.setup()
  local opened_on_files = false
  for _, arg in ipairs(vim.fn.argv()) do
    if vim.fn.isdirectory(arg) == 0 then
      opened_on_files = true
    end
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("worktrees", { clear = true }),
    callback = function()
      if not opened_on_files then
        pcall(M.save_session, current_root())
      end
    end,
  })
end

return M
