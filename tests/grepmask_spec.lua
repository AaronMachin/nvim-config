-- lua/grepmask: masks kept per project, the recent list, and the ripgrep command.

local H = require "test_helpers"

local grepmask

describe("grepmask", function()
  local paths

  before_each(function()
    grepmask = require "grepmask"
    paths = H.isolate()
  end)

  after_each(function()
    H.restore()
  end)

  it("keeps the active mask per project, tidied, in its own state file", function()
    grepmask.set_mask "*.php ,  !*Test.php,,"
    assert.equals("*.php, !*Test.php", grepmask.active_mask())
    assert.equals(paths.dir .. "/grepmask.json", grepmask.state_path)
    local other = H.tmpdir "other"
    vim.cmd.cd(other)
    assert.is_nil(grepmask.active_mask())
    vim.cmd.cd(paths.start)
    assert.equals("*.php, !*Test.php", grepmask.active_mask())
    grepmask.set_mask "  "
    assert.is_nil(grepmask.active_mask())
  end)

  it("keeps recent masks newest first, once each, at most 20", function()
    for i = 1, 25 do
      grepmask.set_mask("*." .. i)
    end
    grepmask.set_mask "*.3"
    local state = vim.json.decode(H.read(grepmask.state_path))
    assert.equals(20, #state.recent)
    assert.equals("*.3", state.recent[1])
    assert.equals("*.25", state.recent[2])
    assert.equals(1, #vim.tbl_filter(function(m)
      return m == "*.3"
    end, state.recent))
  end)

  it("survives an unreadable state file", function()
    H.write(grepmask.state_path, "not json")
    assert.is_nil(grepmask.active_mask())
    grepmask.set_mask "*.lua"
    assert.equals("*.lua", grepmask.active_mask())
  end)

  describe("the command", function()
    local function has(args, value)
      return vim.tbl_contains(args, value)
    end

    it("searches for the text as written by default, with the default excludes before the mask", function()
      local args =
        grepmask.build_command("a.b", "*.php, !vendor/**", { case = false, word = false, regex = false }, true)
      assert.is_true(has(args, "--fixed-strings"))
      assert.is_false(has(args, "--case-sensitive"))
      local first_default = vim.fn.index(args, "--glob=!*.lock")
      local mask = vim.fn.index(args, "--glob=*.php")
      assert.is_true(first_default >= 0 and mask > first_default)
      assert.same({ "--", "a.b" }, vim.list_slice(args, #args - 1))
    end)

    it("follows the case, word and regex options, and can leave the defaults out", function()
      local args = grepmask.build_command("x", "", { case = true, word = true, regex = true }, false)
      assert.is_true(has(args, "--case-sensitive"))
      assert.is_true(has(args, "--word-regexp"))
      assert.is_false(has(args, "--fixed-strings"))
      assert.is_false(has(args, "--glob=!*.lock"))
    end)

    it("gives nothing to run for an empty search", function()
      assert.is_nil(grepmask.build_command("", "*.php", {}, true))
    end)
  end)
end)
