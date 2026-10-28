-- lua/gitkeys (the ticket from the branch, the GitHub link) and lua/pins (pins kept
-- per branch), in throwaway repos.

local H = require "test_helpers"

describe("gitkeys", function()
  local gitkeys, repo, opened

  before_each(function()
    H.isolate()
    gitkeys = require "gitkeys"
    repo = H.repo()
    vim.cmd.cd(repo.main)
    opened = {}
    H.stub(vim.ui, "open", function(url)
      table.insert(opened, url)
    end)
  end)

  after_each(function()
    H.restore()
    vim.cmd "silent! %bwipeout!"
  end)

  it("opens the Jira ticket at the start of the branch", function()
    H.git(repo.main, { "switch", "-q", "-c", "SD-486-backend-login" })
    gitkeys.open_ticket()
    assert.same({ "https://totara.atlassian.net/browse/SD-486" }, opened)
  end)

  it("says so for a branch without a ticket, or a detached HEAD", function()
    local messages = H.capture_notify()
    H.git(repo.main, { "switch", "-q", "-c", "tidy-sd-486" })
    gitkeys.open_ticket()
    assert.is_not_nil(H.notified(messages, "tidy%-sd%-486 doesn't start with a Jira key"))
    H.git(repo.main, { "switch", "-q", "--detach" })
    gitkeys.open_ticket()
    assert.is_not_nil(H.notified(messages, "a detached HEAD doesn't start"))
    assert.same({}, opened)
  end)

  it("asks gh for the file at the lines on the branch, or at the commit when detached", function()
    local bin = H.fake_bin()
    local log = H.tmpdir "gh" .. "/args"
    H.script(bin, "gh", ('echo "$@" >>%q'):format(log))
    H.edit(repo.main .. "/README.md")
    gitkeys.open_on_github()
    H.wait(2000, function()
      return H.read(log) ~= nil
    end)
    assert.equals("browse README.md:1 --branch main\n", H.read(log))

    H.git(repo.main, { "switch", "-q", "--detach" })
    os.remove(log)
    gitkeys.open_on_github()
    H.wait(2000, function()
      return H.read(log) ~= nil
    end)
    local sha = H.git(repo.main, { "rev-parse", "HEAD" })
    assert.equals("browse README.md:1 --commit=" .. sha .. "\n", H.read(log))
  end)
end)

describe("pins", function()
  local pins, repo, messages

  before_each(function()
    H.isolate()
    pins = require "pins"
    repo = H.repo()
    vim.cmd.cd(repo.main)
    H.write(repo.main .. "/a.txt", "a\n")
    messages = H.capture_notify()
  end)

  after_each(function()
    H.restore()
    vim.cmd "silent! %bwipeout!"
  end)

  it("keeps a list per branch, stored relative to the repo", function()
    H.edit(repo.main .. "/a.txt")
    pins.add()
    assert.is_not_nil(H.notified(messages, "pinned a.txt as 1"))
    pins.add()
    assert.is_not_nil(H.notified(messages, "already pinned as 1"))

    vim.cmd "enew"
    pins.jump(1)
    assert.equals(repo.main .. "/a.txt", vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))

    H.git(repo.main, { "switch", "-q", "-c", "other" })
    vim.cmd "enew"
    pins.jump(1)
    assert.is_not_nil(H.notified(messages, "nothing pinned at 1"))

    H.git(repo.main, { "switch", "-q", "main" })
    pins.jump(1)
    assert.equals(repo.main .. "/a.txt", vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
  end)

  it("won't pin something that isn't a file", function()
    vim.cmd "enew"
    pins.add()
    assert.is_not_nil(H.notified(messages, "not a file"))
  end)
end)
