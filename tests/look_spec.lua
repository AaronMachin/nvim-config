-- lua/floatterm/look and bin/floatterm-look: a tab lit up purple when Claude has found
-- something for you, cleared when you go into it.

local H = require "test_helpers"

local api = vim.api
local ft, look, tabbar

-- Runs bin/floatterm-look as Claude in the tab `buf` would.
local function run(args, buf)
  local started = vim.v.servername == "" and vim.fn.serverstart "127.0.0.1:0" or nil
  local env = { NVIM = started or vim.v.servername, FLOATTERM_TAB_ID = buf and tostring(ft.record(buf).id) or "" }
  local done
  vim.system(vim.list_extend({ H.config .. "/bin/floatterm-look" }, args), { text = true, env = env }, function(result)
    done = result
  end)
  H.wait(10000, function()
    return done ~= nil
  end, "floatterm-look didn't finish")
  if started then
    vim.fn.serverstop(started)
  end
  return done
end

local function bar_text()
  tabbar.redraw()
  return table.concat(tabbar.lines(), "\n")
end

local function note_text()
  local win = look.note_window()
  return win and table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n") or nil
end

describe("look at this", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    look = require "floatterm.look"
    tabbar = require "floatterm.tabbar"
    tabbar.setup()
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
    pcall(vim.cmd, "stopinsert")
  end)

  it("lights up another tab with the line in place of its state, until you go into it", function()
    local triage = H.sleep_tab { label = "triage" }
    H.sleep_tab { label = "other" }
    api.nvim_set_current_win(ft.window())
    local result = run({ "Found it: the retry loop never backs off" }, triage)
    assert.equals(0, result.code, result.stderr)
    assert.equals("flagged", vim.trim(result.stdout))
    assert.equals("Found it: the retry loop never backs off", ft.record(triage).look)
    assert.truthy(bar_text():find("Found it: the retry", 1, true), bar_text())

    ft.focus_buf(triage)
    H.wait(1000, function()
      return ft.record(triage).look == nil
    end, "not cleared on arrival")
    assert.truthy((note_text() or ""):find("retry loop", 1, true), note_text())
    assert.is_nil(bar_text():find("Found it", 1, true))
  end)

  it("only shows the line on a tab you're already looking at", function()
    local here = H.sleep_tab { label = "here" }
    api.nvim_set_current_win(ft.window())
    local result = run({ "PR note held for your OK" }, here)
    assert.equals("shown", vim.trim(result.stdout))
    assert.is_nil(ft.record(here).look)
    assert.truthy((note_text() or ""):find("PR note held", 1, true))
  end)

  it("says so outside a floatterm tab", function()
    local result = run({ "anything" }, nil)
    assert.equals(1, result.code)
    assert.truthy(result.stderr:find("not running in a floatterm tab", 1, true), result.stderr)
  end)

  describe("the safety net", function()
    local triage

    before_each(function()
      triage = H.sleep_tab { label = "triage" }
      H.sleep_tab { label = "other" }
    end)

    it("lights up a tab Claude didn't flag itself", function()
      look.from_summary(ft.record(triage), "CI needs a fresh run")
      assert.equals("CI needs a fresh run", ft.record(triage).look)
    end)

    it("leaves a tab Claude flagged itself this turn, or with nothing for you", function()
      look.from_summary(ft.record(triage), "")
      assert.is_nil(ft.record(triage).look)
      look.flag(ft.record(triage).id, "Claude's own words")
      ft.update(triage, { look = vim.NIL })
      look.from_summary(ft.record(triage), "Haiku's words")
      assert.is_nil(ft.record(triage).look)
    end)

    it("doesn't flag the same line again once you've cleared it", function()
      look.from_summary(ft.record(triage), "CI needs a fresh run")
      ft.update(triage, { look = vim.NIL })
      look.from_summary(ft.record(triage), "CI needs a fresh run")
      assert.is_nil(ft.record(triage).look)
      look.from_summary(ft.record(triage), "Something new")
      assert.equals("Something new", ft.record(triage).look)
    end)
  end)
end)
