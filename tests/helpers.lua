-- Shared helpers for the specs. Every path a module writes to is pointed at a fresh
-- temporary folder by H.isolate(), and stubs made with H.stub are put back by
-- H.restore().

local H = {}

local api = vim.api

H.root = vim.env.NVIM_TEST_ROOT
H.config = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- A new empty folder, with symlinks resolved (macOS's /var is /private/var).
function H.tmpdir(name)
  local dir = vim.fn.tempname() .. (name and ("-" .. name) or "")
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

function H.write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
  return path
end

function H.read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read "*a"
  file:close()
  return text
end

function H.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

function H.wait(ms, condition, message)
  local ok = vim.wait(ms, condition, 10)
  assert(ok, message or "timed out waiting")
end

-- Lets scheduled callbacks run.
function H.flush(ms)
  vim.wait(ms or 50, function()
    return false
  end, 10)
end

-- Stubs ---------------------------------------------------------------------

local stubs = {}

function H.stub(tbl, key, value)
  table.insert(stubs, { tbl, key, tbl[key] })
  tbl[key] = value
  return value
end

function H.restore()
  for i = #stubs, 1, -1 do
    local s = stubs[i]
    s[1][s[2]] = s[3]
  end
  stubs = {}
end

-- Collects vim.notify messages: returns the list, each { msg, level }.
function H.capture_notify()
  local messages = {}
  H.stub(vim, "notify", function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end)
  return messages
end

function H.notified(messages, pattern)
  for _, m in ipairs(messages) do
    if tostring(m.msg):find(pattern) then
      return m
    end
  end
  return nil
end

-- Answers the next vim.ui.select / vim.ui.input calls in order. Each answer is a
-- function(items, opts) or a value; for select a string picks the item equal to it
-- (or whose .text is). Returns the list of prompts seen.
function H.answer_select(...)
  local answers, prompts = { ... }, {}
  H.stub(vim.ui, "select", function(items, opts, on_choice)
    table.insert(prompts, opts.prompt or "")
    local answer = table.remove(answers, 1)
    if type(answer) == "function" then
      answer = answer(items, opts)
    elseif type(answer) == "string" then
      for _, item in ipairs(items) do
        if item == answer or (type(item) == "table" and item.text == answer) then
          answer = item
          break
        end
      end
    end
    on_choice(answer)
  end)
  return prompts
end

function H.answer_input(...)
  local answers, prompts = { ... }, {}
  H.stub(vim.ui, "input", function(opts, on_confirm)
    table.insert(prompts, opts.prompt or "")
    on_confirm(table.remove(answers, 1))
  end)
  return prompts
end

-- Fake programs -------------------------------------------------------------

-- A folder of fake programs put first on PATH until H.restore().
function H.fake_bin()
  local dir = H.tmpdir "bin"
  H.stub(vim.env, "PATH", dir .. ":" .. vim.env.PATH)
  return dir
end

function H.script(dir, name, body)
  local path = H.write(dir .. "/" .. name, "#!/bin/sh\n" .. body .. "\n")
  vim.uv.fs_chmod(path, 493)
  return path
end

-- Isolation -----------------------------------------------------------------

-- Points every module's files at a fresh temporary folder and cds into a fresh start
-- folder. Returns { dir, start }.
function H.isolate()
  local dir = H.tmpdir "case"
  local start = dir .. "/start"
  vim.fn.mkdir(start, "p")
  vim.cmd.cd(vim.fn.fnameescape(start))

  local settings = require "floatterm.settings"
  settings.path = dir .. "/floatterm-settings.json"
  settings.reload()
  if package.loaded["floatterm"] then
    package.loaded["floatterm"].placement_dir = dir .. "/placement"
  end
  if package.loaded["floatterm.notes"] then
    package.loaded["floatterm.notes"].folder = start
  end
  if package.loaded["grepmask"] then
    package.loaded["grepmask"].state_path = dir .. "/grepmask.json"
  end
  if package.loaded["worktrees"] then
    package.loaded["worktrees"].sessions_dir = dir .. "/sessions"
  end
  if package.loaded["floatterm.restore"] then
    package.loaded["floatterm.restore"].dir = dir .. "/tabs"
  end
  return { dir = dir, start = start }
end

-- Terminal tabs ---------------------------------------------------------------

-- A tab running `sleep`, standing in for a shell or Claude.
function H.sleep_tab(opts)
  local _, buf = require("floatterm").new_tab({ "sleep", "300" }, opts)
  return buf
end

-- Stops every tab and waits for them to go, and hides the float.
function H.close_all_tabs()
  local ft = package.loaded["floatterm"]
  if not ft then
    return
  end
  for _, record in ipairs(ft.tabs()) do
    pcall(vim.fn.jobstop, record.job)
  end
  vim.wait(3000, function()
    return #ft.tabs() == 0
  end, 10)
  ft.hide()
  H.flush(30)
end

-- Every window but the first normal one closed.
function H.close_floats()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative ~= "" then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

-- A file in a buffer of its own, in the current window.
function H.edit(path, lines)
  if lines then
    H.write(path, table.concat(lines, "\n") .. "\n")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf()
end

-- Child nvims ---------------------------------------------------------------

-- Runs `lua` in a fresh headless nvim (this config, the same isolation) started in
-- `cwd`, with `globals` set as vim.g before anything loads. Whatever the code writes
-- with io.stdout:write comes back. It quits once the code returns, unless the code
-- quits itself.
function H.child(cwd, lua, globals, timeout)
  local args = { vim.v.progpath, "--headless", "--noplugin" }
  for key, value in pairs(globals or {}) do
    vim.list_extend(args, { "--cmd", ("lua vim.g[%q] = vim.json.decode(%q)"):format(key, vim.json.encode(value)) })
  end
  local script = H.write(H.tmpdir "child" .. "/script.lua", lua)
  vim.list_extend(args, { "-u", H.config .. "/tests/minimal_init.lua", "-c", "luafile " .. script, "-c", "qa!" })
  local result = vim.system(args, { cwd = cwd, text = true, env = { NVIM_TEST_CHILD = "1" } }):wait(timeout or 20000)
  return result.stdout or "", result
end

-- git -------------------------------------------------------------------------

function H.git(dir, args)
  local result = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  assert(result.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. (result.stderr or ""))
  return vim.trim(result.stdout or "")
end

-- A repo with one commit on main, cloned from a bare "origin" beside it. Returns
-- { origin, main }.
function H.repo(parent)
  parent = parent or H.tmpdir "repos"
  local origin = parent .. "/origin.git"
  local seed = parent .. "/seed"
  vim.fn.mkdir(seed, "p")
  H.git(seed, { "init", "-q", "-b", "main" })
  H.write(seed .. "/README.md", "hello\n")
  H.git(seed, { "add", "." })
  H.git(seed, { "commit", "-q", "-m", "first" })
  H.git(parent, { "clone", "-q", "--bare", seed, origin })
  local main = parent .. "/app"
  H.git(parent, { "clone", "-q", origin, main })
  return { origin = origin, main = vim.uv.fs_realpath(main), parent = parent }
end

return H
