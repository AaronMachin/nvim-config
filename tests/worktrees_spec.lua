-- lua/worktrees, in throwaway repos each test builds (a bare origin and a clone):
-- listing, creating one for a ticket, moving nvim between them with sessions, and
-- switch_main with its undo.

local H = require "test_helpers"
local api = vim.api

local worktrees, repo, messages

local function add_worktree(name, branch)
  local dir = repo.parent .. "/app-" .. name
  H.git(repo.main, { "worktree", "add", "-q", "-b", branch, dir })
  return vim.uv.fs_realpath(dir)
end

local function wait_for(pattern)
  H.wait(10000, function()
    return H.notified(messages, pattern) ~= nil
  end, "no notification matching " .. pattern)
end

describe("worktrees", function()
  before_each(function()
    H.isolate()
    worktrees = require "worktrees"
    H.isolate()
    repo = H.repo()
    vim.cmd.cd(repo.main)
    messages = H.capture_notify()
    -- No Claude tabs in these repos.
    H.stub(require "agent", "tab_for", function() end)
  end)

  after_each(function()
    H.restore()
    vim.cmd "silent! %bwipeout!"
  end)

  it("lists the main checkout first, with branches, last commits and uncommitted counts", function()
    local wt = add_worktree("sd-1-x", "SD-1-x")
    H.write(wt .. "/new.txt", "x\n")
    local list = worktrees.list()
    assert.equals(2, #list)
    assert.is_true(list[1].is_main)
    assert.is_true(list[1].is_current)
    assert.equals("main", list[1].branch)
    assert.equals("SD-1-x", list[2].branch)
    assert.equals("first", list[2].subject)
    assert.equals(0, list[1].changes)
    assert.equals(1, list[2].changes)
  end)

  describe("create", function()
    it("makes <main>-<ticket>-<name> on a new branch from the fetched default branch", function()
      H.answer_input("sd-501", "backend")
      H.answer_select("No", "No")
      -- A commit on origin the clone hasn't fetched yet.
      local seed = repo.parent .. "/seed"
      H.write(seed .. "/later.txt", "later\n")
      H.git(seed, { "add", "." })
      H.git(seed, { "commit", "-q", "-m", "later" })
      H.git(seed, { "push", "-q", repo.origin, "main" })

      worktrees.create()
      wait_for "created SD%-501%-backend in app%-sd%-501%-backend from origin/main"
      local folder = repo.parent .. "/app-sd-501-backend"
      assert.equals("SD-501-backend", H.git(folder, { "branch", "--show-current" }))
      assert.is_true(H.exists(folder .. "/later.txt"))
      -- Not moved.
      assert.equals(repo.main, vim.uv.fs_realpath(vim.uv.cwd()))
    end)

    it("refuses a branch that exists, and an empty name", function()
      H.git(repo.main, { "branch", "SD-2-x" })
      H.answer_input("sd-2", "x")
      worktrees.create()
      wait_for "branch SD%-2%-x already exists"
      H.answer_input("sd-3", "  ")
      worktrees.create()
      wait_for "a short name is needed"
    end)
  end)

  describe("moving nvim", function()
    it("saves the session it leaves, closes its files and brings the other's back", function()
      local wt = add_worktree("b", "b")
      worktrees.sessions_dir = H.tmpdir "sessions"
      H.edit(repo.main .. "/README.md")
      assert.is_true(worktrees.switch(wt))
      assert.equals(wt, vim.uv.fs_realpath(vim.uv.cwd()))
      assert.is_true(H.exists(worktrees.session_path(repo.main)))
      for _, buf in ipairs(api.nvim_list_bufs()) do
        assert.is_not.equals(repo.main .. "/README.md", api.nvim_buf_get_name(buf))
      end
      H.edit(wt .. "/README.md")
      assert.is_true(worktrees.switch(repo.main))
      wait_for "session restored"
      assert.equals(repo.main .. "/README.md", vim.uv.fs_realpath(api.nvim_buf_get_name(0)))
    end)

    it("refuses while a file has unsaved changes", function()
      local wt = add_worktree("c", "c")
      H.edit(repo.main .. "/README.md")
      api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
      assert.is_false(worktrees.switch(wt))
      wait_for "save or discard these first: README.md"
      assert.equals(repo.main, vim.uv.fs_realpath(vim.uv.cwd()))
      vim.cmd "edit!"
    end)
  end)

  describe("switch_main", function()
    it("stashes main's changes, detaches the worktree and checks its branch out in main", function()
      local wt = add_worktree("sd-9", "SD-9")
      H.write(repo.main .. "/wip.txt", "wip\n")
      local prompts = H.answer_select "Go ahead"
      worktrees.switch_main(wt)
      wait_for "main is on SD%-9"
      assert.truthy(prompts[1]:find("stash 1 uncommitted file, then check out SD-9", 1, true))
      assert.equals("SD-9", H.git(repo.main, { "branch", "--show-current" }))
      assert.equals("", H.git(wt, { "branch", "--show-current" }))
      assert.is_false(H.exists(repo.main .. "/wip.txt"))
      assert.truthy(H.git(repo.main, { "stash", "list" }):find("before switching to SD-9", 1, true))
    end)

    it("offers to undo what it did when a step fails, and puts everything back", function()
      local wt = add_worktree("sd-10", "SD-10")
      H.write(repo.main .. "/wip.txt", "wip\n")
      -- Checking the branch out in main fails; everything else is real git.
      local system = vim.system
      H.stub(vim, "system", function(cmd, opts, on_exit)
        if cmd[1] == "git" and cmd[3] == repo.main and cmd[4] == "switch" and cmd[5] == "SD-10" then
          on_exit { code = 1, stdout = "", stderr = "fatal: made to fail by the test.\nhint: x" }
          return
        end
        return system(cmd, opts, on_exit)
      end)
      local prompts = H.answer_select("Go ahead", "Yes")
      worktrees.switch_main(wt)
      wait_for "undone: "
      assert.truthy(
        H.notified(messages, "checking out SD%-10 in main failed, stopped there: fatal: made to fail by the test%.")
      )
      assert.truthy(prompts[2]:find("Undo what was done?", 1, true))
      -- Back as it was: main on main with its change, the worktree on its branch.
      assert.equals("main", H.git(repo.main, { "branch", "--show-current" }))
      assert.equals("wip\n", H.read(repo.main .. "/wip.txt"))
      assert.equals("SD-10", H.git(wt, { "branch", "--show-current" }))
      assert.equals("", H.git(repo.main, { "stash", "list" }))
    end)

    it("says how to undo by hand when you'd rather not", function()
      local wt = add_worktree("sd-11", "SD-11")
      local system = vim.system
      H.stub(vim, "system", function(cmd, opts, on_exit)
        if cmd[1] == "git" and cmd[3] == repo.main and cmd[4] == "switch" and cmd[5] == "SD-11" then
          on_exit { code = 1, stdout = "", stderr = "fatal: no" }
          return
        end
        return system(cmd, opts, on_exit)
      end)
      H.answer_select("Go ahead", "No")
      worktrees.switch_main(wt)
      wait_for "To undo it by hand"
      assert.truthy(H.notified(messages, "switch 'SD%-11'"))
      assert.equals("", H.git(wt, { "branch", "--show-current" }))
    end)

    it("won't switch to the main checkout itself, or a detached worktree", function()
      worktrees.switch_main(repo.main)
      wait_for "that is the main checkout"
      local wt = add_worktree("d", "d")
      H.git(wt, { "switch", "-q", "--detach" })
      worktrees.switch_main(wt)
      wait_for "is detached"
    end)
  end)
end)
