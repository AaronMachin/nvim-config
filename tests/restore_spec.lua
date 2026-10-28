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
local function restore_in(project, dir, before)
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
  local out, result = H.child(project, code, { floatterm_tabs_dir = dir, floatterm_restore_headless = true })
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
    H.write(dir .. "/" .. folder_key(project) .. "/live.lock", vim.json.encode { pid = vim.fn.getpid() })
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
  end)
end)
