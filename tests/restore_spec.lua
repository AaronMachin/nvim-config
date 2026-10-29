-- lua/floatterm/restore: a saved set of tabs per nvim, saved as tabs change, and
-- reopening them in a fresh nvim (a child nvim per case, as restore runs once per
-- nvim). Driven through vim.g.floatterm_tabs_dir and vim.g.floatterm_restore_headless;
-- Claude tabs resume through a fake `claude`.

local H = require "test_helpers"

local function folder_key(folder)
  return (folder:gsub("/", "%%"))
end

local function sets_in(dir, folder)
  local found = {}
  local where = dir .. "/" .. folder_key(folder)
  if not H.exists(where) then
    return found
  end
  for name in vim.fs.dir(where) do
    local id = name:match "^(.+)%.json$"
    if id then
      found[id] = vim.json.decode(H.read(where .. "/" .. name))
    end
  end
  return found
end

local function write_set(dir, folder, id, set)
  set.folder = folder
  return H.write(dir .. "/" .. folder_key(folder) .. "/" .. id .. ".json", vim.json.encode(set))
end

-- Restores in a fresh nvim in `project`, with `before` run first (stubs, say), and
-- returns what it opened.
local function restore_in(project, dir, before, opts)
  local code = (before or "")
    .. [[
    local r = require "floatterm.restore"
    r.setup()
    r.restore()
    vim.wait(500, function() return false end, 20)
    local out = { state = r.state(), tabs = {}, prompts = _G.prompts }
    for _, t in ipairs(require("floatterm").tabs()) do
      table.insert(out.tabs, {
        kind = t.kind, label = t.label, cwd = t.cwd, last_command = t.last_command,
        session_id = t.session_id, title = t.title, status = t.status,
        note_id = t.note_id, notes_on = t.notes_on,
      })
    end
    io.stdout:write(vim.json.encode(out))
  ]]
  local out, result = H.child(project, code, { floatterm_tabs_dir = dir, floatterm_restore_headless = true }, nil, opts)
  local ok, decoded = pcall(vim.json.decode, out)
  assert(ok, "child nvim said: " .. out .. (result.stderr or ""))
  return decoded
end

describe("restore", function()
  local dir, project, bin, claude_log

  before_each(function()
    H.isolate()
    dir = H.tmpdir "tabs"
    project = H.tmpdir "project"
    bin = H.fake_bin()
    claude_log = H.tmpdir "claude" .. "/args"
    H.script(bin, "claude", ('echo "$@" >>%q\nexec sleep 300'):format(claude_log))
  end)

  after_each(function()
    H.restore()
  end)

  it("opens the one saved set: fresh shells keeping what last ran, Claude tabs resumed with their state", function()
    local transcript = H.write(H.tmpdir "t" .. "/s1.jsonl", "{}\n")
    write_set(dir, project, "20261001-100000-1", {
      saved_at = 100,
      tabs = {
        {
          kind = "shell",
          cwd = project,
          label = "server",
          last_command = "npm run dev",
          note_id = "20261001-nnnn",
          notes_on = true,
        },
        {
          kind = "claude",
          cwd = project,
          label = "api",
          session_id = "s1",
          transcript_path = transcript,
          title = "✳ Fixing login",
          status = "done",
          last_prompt = "fix it",
        },
      },
    })
    local out = restore_in(project, dir)
    assert.equals(2, #out.tabs)
    local shell, claude = out.tabs[1], out.tabs[2]
    assert.equals("server", shell.label)
    assert.equals("npm run dev", shell.last_command)
    assert.equals("20261001-nnnn", shell.note_id)
    assert.is_true(shell.notes_on)
    assert.equals("claude", claude.kind)
    assert.equals("s1", claude.session_id)
    assert.equals("✳ Fixing login", claude.title)
    assert.equals("done", claude.status)
    assert.truthy(H.read(claude_log):find("--resume s1", 1, true))
    -- It took the set over, rather than making another.
    assert.equals("20261001-100000-1", out.state.current)
  end)

  it("starts a fresh claude for a tab whose conversation was never written", function()
    write_set(dir, project, "a", {
      saved_at = 1,
      tabs = { { kind = "claude", cwd = project, label = "api", session_id = "never-written" } },
    })
    local out = restore_in(project, dir)
    assert.equals(1, #out.tabs)
    assert.is_nil(H.read(claude_log):find("--resume", 1, true))
  end)

  it("keeps a Claude tab whose folder is gone for one more try, then gives up", function()
    write_set(dir, project, "a", {
      saved_at = 1,
      tabs = {
        { kind = "shell", cwd = project },
        { kind = "claude", cwd = project .. "/gone", label = "lost", session_id = "x" },
      },
    })
    restore_in(project, dir)
    local saved = sets_in(dir, project).a
    assert.equals(2, #saved.tabs)
    assert.equals(1, saved.tabs[2].attempts)
    restore_in(project, dir)
    saved = sets_in(dir, project).a
    assert.equals(1, #saved.tabs)
  end)

  it("asks which set to open when there are several", function()
    write_set(dir, project, "older", { saved_at = 100, tabs = { { kind = "shell", cwd = project, label = "old" } } })
    write_set(dir, project, "newer", { saved_at = 200, tabs = { { kind = "shell", cwd = project, label = "new" } } })
    local out = restore_in(
      project,
      dir,
      [[
      local r = require "floatterm.restore"
      r.pick = function(sets, on_choice)
        _G.prompts = vim.tbl_map(function(s) return s.id end, sets)
        on_choice(sets[2])
      end
    ]]
    )
    assert.same({ "newer", "older" }, out.prompts)
    assert.equals("old", out.tabs[1].label)
    assert.equals("older", out.state.current)
  end)

  it("starts fresh when the picker is closed", function()
    write_set(dir, project, "one", { saved_at = 100, tabs = { { kind = "shell", cwd = project } } })
    write_set(dir, project, "two", { saved_at = 200, tabs = { { kind = "shell", cwd = project } } })
    local out = restore_in(
      project,
      dir,
      [[
      require("floatterm.restore").pick = function(_, on_choice) on_choice(nil) end
    ]]
    )
    assert.equals(0, #out.tabs)
    assert.is_nil(out.state.current)
    assert.is_true(out.state.done)
  end)

  it("offers a copy of the tabs another running nvim has, mentioning the shared notes", function()
    write_set(dir, project, "live", { saved_at = 100, tabs = { { kind = "shell", cwd = project, label = "theirs" } } })
    -- This test's own nvim stands in for the other one.
    H.write(
      dir .. "/" .. folder_key(project) .. "/live.lock",
      vim.json.encode { pid = vim.fn.getpid(), server = vim.v.servername }
    )
    local out = restore_in(
      project,
      dir,
      [[
      vim.ui.select = function(items, opts, on_choice)
        _G.prompts = { opts.prompt, items[1].text }
        on_choice(items[1])
      end
    ]]
    )
    assert.truthy(out.prompts[1]:find("Another nvim is open", 1, true))
    assert.truthy(out.prompts[2]:find("share the same notes", 1, true))
    assert.equals("theirs", out.tabs[1].label)
    assert.is_not.equals("live", out.state.current)
    -- The other nvim's set and lock are left alone.
    local sets = sets_in(dir, project)
    assert.is_not_nil(sets.live)
    assert.is_not_nil(sets[out.state.current])
    assert.is_true(H.exists(dir .. "/" .. folder_key(project) .. "/live.lock"))
  end)

  it("ignores a lock left by an nvim that crashed", function()
    write_set(dir, project, "crashed", { saved_at = 100, tabs = { { kind = "shell", cwd = project, label = "mine" } } })
    H.write(dir .. "/" .. folder_key(project) .. "/crashed.lock", vim.json.encode { pid = 999999 })
    local out = restore_in(
      project,
      dir,
      [[
      vim.ui.select = function() error "shouldn't ask" end
    ]]
    )
    assert.equals("crashed", out.state.current)
    assert.equals("mine", out.tabs[1].label)
  end)

  it("ignores a lock whose pid is a running nvim but not the one at its server address", function()
    write_set(dir, project, "reused", { saved_at = 100, tabs = { { kind = "shell", cwd = project, label = "mine" } } })
    -- The pid is an nvim (this one), but the address is a crashed one's. Kept short: a
    -- socket path past macOS's 104 characters is cut, and could reach this nvim's.
    H.write(
      dir .. "/" .. folder_key(project) .. "/reused.lock",
      vim.json.encode { pid = vim.fn.getpid(), server = "/nonexistent/nvim.1.0" }
    )
    local out = restore_in(
      project,
      dir,
      [[
      vim.ui.select = function() error "shouldn't ask" end
    ]]
    )
    assert.equals("reused", out.state.current)
  end)

  it("takes a lock still being written for another nvim's", function()
    write_set(dir, project, "new", { saved_at = 100, tabs = { { kind = "shell", cwd = project, label = "theirs" } } })
    H.write(dir .. "/" .. folder_key(project) .. "/new.lock", "")
    local out = restore_in(
      project,
      dir,
      [[
      vim.ui.select = function(items, _, on_choice)
        _G.prompts = { "asked" }
        on_choice(items[#items])
      end
    ]]
    )
    assert.same({ "asked" }, out.prompts)
    assert.is_not.equals("new", out.state.current)
    assert.equals("", H.read(dir .. "/" .. folder_key(project) .. "/new.lock"))
  end)

  it("lets only one of two nvims racing for a crashed nvim's lock have the set", function()
    write_set(dir, project, "stale", { saved_at = 100, tabs = { { kind = "shell", cwd = project, label = "mine" } } })
    H.write(dir .. "/" .. folder_key(project) .. "/stale.lock", vim.json.encode { pid = 999999 })
    local go = H.tmpdir "go" .. "/go"
    -- Both start together. Asking whether pid 999999 is running takes a while the
    -- second time (as the lock is taken), longer for the second nvim, so it decides the
    -- lock is stale only after the first has taken it over.
    local function racer(delay)
      return H.child_start(
        project,
        ([[
        local get_proc, calls = vim.api.nvim_get_proc, 0
        vim.api.nvim_get_proc = function(pid)
          if pid == 999999 then
            calls = calls + 1
            if calls == 2 then
              vim.uv.sleep(%d)
            end
            return nil
          end
          return get_proc(pid)
        end
        vim.ui.select = function(items, _, on_choice) on_choice(items[#items]) end
        vim.notify = function() end
        vim.wait(5000, function() return vim.uv.fs_stat(%q) ~= nil end, 5)
        local r = require "floatterm.restore"
        r.setup()
        r.restore()
        vim.wait(1500, function() return false end, 20)
        io.stdout:write(r.state().current or "none")
      ]]):format(delay, go),
        { floatterm_tabs_dir = dir, floatterm_restore_headless = true }
      )
    end
    local first, second = racer(100), racer(700)
    H.flush(500)
    H.write(go, "")
    local a, b = first:wait(20000).stdout, second:wait(20000).stdout
    local owners = (a == "stale" and 1 or 0) + (b == "stale" and 1 or 0)
    assert.equals(1, owners, "first: " .. a .. ", second: " .. b)
  end)

  it("turns the old single saved file into a set", function()
    H.write(
      dir .. "/" .. folder_key(project) .. ".json",
      vim.json.encode { { kind = "shell", cwd = project, label = "old" } }
    )
    local out = restore_in(project, dir)
    assert.equals("old", out.tabs[1].label)
    assert.is_false(H.exists(dir .. "/" .. folder_key(project) .. ".json"))
    local ids = vim.tbl_keys(sets_in(dir, project))
    assert.equals(1, #ids)
    assert.truthy(ids[1]:find "%-migrated$")
  end)

  it("finishes a migration that an nvim crashed part-way through", function()
    for _, name in ipairs { "migrating.tmp999999", "migrating-999999.old" } do
      local here = H.tmpdir "project"
      H.write(
        dir .. "/" .. folder_key(here) .. "/" .. name,
        vim.json.encode { { kind = "shell", cwd = here, label = "old" } }
      )
      local out = restore_in(here, dir)
      assert.equals("old", out.tabs[1] and out.tabs[1].label, name)
      assert.is_false(H.exists(dir .. "/" .. folder_key(here) .. "/" .. name), name)
      local ids = vim.tbl_keys(sets_in(dir, here))
      assert.equals(1, #ids, name)
      assert.truthy(ids[1]:find "%-migrated$", name)
    end
  end)

  it("keeps the 10 most recently saved sets", function()
    for i = 1, 12 do
      write_set(dir, project, ("set%02d"):format(i), { saved_at = i, tabs = { { kind = "shell", cwd = project } } })
    end
    write_set(dir, project, "empty", { saved_at = 50, tabs = {} })
    restore_in(
      project,
      dir,
      [[
      require("floatterm.restore").pick = function(_, on_choice) on_choice(nil) end
    ]]
    )
    local sets = sets_in(dir, project)
    assert.equals(10, vim.tbl_count(sets))
    assert.is_nil(sets.set01)
    assert.is_nil(sets.set02)
    assert.is_nil(sets.empty)
    assert.is_not_nil(sets.set12)
  end)

  it("does nothing with reopen_tabs off", function()
    write_set(dir, project, "a", { saved_at = 1, tabs = { { kind = "shell", cwd = project } } })
    local out = restore_in(
      project,
      dir,
      [[
      require("floatterm.settings").set("reopen_tabs", false)
    ]]
    )
    assert.equals(0, #out.tabs)
    assert.is_false(out.state.done)
  end)

  describe("saving", function()
    it("writes this nvim's set as tabs change, Claude state kept and working read as done", function()
      local out = H.child(
        project,
        [[
        local r = require "floatterm.restore"
        r.setup()
        r.restore()
        local ft = require "floatterm"
        ft.new_tab({ "sleep", "300" }, { label = "server" })
        local _, buf = ft.new_tab({ "sleep", "300" }, { label = "api", kind = "claude" })
        ft.update(buf, { session_id = "s9", status = "working", title = "✳ Doing it", note_id = "n1", notes_on = true })
        -- Saved a second or two after the change, without being asked.
        local path = r.state().dir .. "/" .. (r.state().current or "") .. ".json"
        vim.wait(4000, function()
          local f = io.open(r.state().dir .. "/" .. (r.state().current or "x") .. ".json")
          if not f then return false end
          local set = vim.json.decode(f:read "*a")
          f:close()
          return #set.tabs == 2 and set.tabs[2].session_id == "s9"
        end, 50)
        io.stdout:write(r.state().current or "")
      ]],
        { floatterm_tabs_dir = dir, floatterm_restore_headless = true }
      )
      assert.is_true(out ~= "")
      local set = sets_in(dir, project)[out]
      assert.equals(2, #set.tabs)
      assert.equals("server", set.tabs[1].label)
      local claude = set.tabs[2]
      assert.equals("s9", claude.session_id)
      assert.equals("done", claude.status)
      assert.equals("✳ Doing it", claude.title)
      assert.equals("n1", claude.note_id)
      assert.is_true(claude.notes_on)
      -- Its lock went with it on quit.
      assert.is_false(H.exists(dir .. "/" .. folder_key(project) .. "/" .. out .. ".lock"))
    end)

    it("never makes a set for an nvim that had no tabs", function()
      H.child(
        project,
        [[
        local r = require "floatterm.restore"
        r.setup()
        r.restore()
      ]],
        { floatterm_tabs_dir = dir, floatterm_restore_headless = true }
      )
      assert.equals(0, vim.tbl_count(sets_in(dir, project)))
    end)

    it("saves without waiting on ps, using the commands it last knew", function()
      H.script(bin, "ps", "sleep 3")
      local out = H.child(
        project,
        [[
        local r = require "floatterm.restore"
        r.setup()
        r.restore()
        local ft = require "floatterm"
        local tabbar = require "floatterm.tabbar"
        ft.new_tab(nil, { label = "server" })
        local runs = tabbar.ps_runs
        local start = vim.uv.hrtime()
        r.save(true)
        local periodic = (vim.uv.hrtime() - start) / 1e6
        start = vim.uv.hrtime()
        vim.api.nvim_exec_autocmds("VimLeavePre", {})
        local quit = (vim.uv.hrtime() - start) / 1e6
        io.stdout:write(vim.json.encode { periodic = periodic, quit = quit, asked = tabbar.ps_runs - runs })
      ]],
        { floatterm_tabs_dir = dir, floatterm_restore_headless = true }
      )
      local times = vim.json.decode(out)
      assert.is_true(times.periodic < 200, "periodic save took " .. times.periodic .. "ms")
      assert.is_true(times.quit < 200, "quit save took " .. times.quit .. "ms")
      -- The periodic save still asks, for next time.
      assert.equals(1, times.asked)
    end)

    it("does nothing for nvim opened on a file", function()
      H.write(project .. "/file.txt", "x\n")
      write_set(dir, project, "a", { saved_at = 1, tabs = { { kind = "shell", cwd = project } } })
      local out = H.child(
        project,
        [[
        vim.cmd.argadd "file.txt"
        local r = require "floatterm.restore"
        r.setup()
        r.restore()
        io.stdout:write(tostring(#require("floatterm").tabs()))
      ]],
        { floatterm_tabs_dir = dir, floatterm_restore_headless = true }
      )
      assert.equals("0", out)
    end)

    it("does nothing for nvim reading stdin, a session, an error file or only +cmd", function()
      local session = H.write(H.tmpdir "session" .. "/session.vim", "\n")
      local errors = H.write(project .. "/errors.txt", "file.txt:1:oops\n")
      H.write(project .. "/file.txt", "x\n")
      write_set(dir, project, "a", { saved_at = 1, tabs = { { kind = "shell", cwd = project } } })
      for _, case in ipairs {
        { args = { "-" }, stdin = "from stdin\n" },
        { args = { "-S", session } },
        { args = { "-q", errors } },
        { args = { "+set nomore" } },
      } do
        local out = H.child(
          project,
          [[
          vim.ui.select = function() error "shouldn't ask" end
          local r = require "floatterm.restore"
          r.setup()
          r.restore()
          io.stdout:write(tostring(#require("floatterm").tabs()))
        ]],
          { floatterm_tabs_dir = dir, floatterm_restore_headless = true },
          nil,
          case
        )
        assert.equals("0", out, case.args[1])
      end
    end)

    it("restores for nvim opened on its folder", function()
      write_set(dir, project, "a", { saved_at = 1, tabs = { { kind = "shell", cwd = project, label = "here" } } })
      local out = restore_in(H.tmpdir "elsewhere", dir, nil, { args = { project } })
      assert.equals("here", out.tabs[1].label)
    end)
  end)
end)
