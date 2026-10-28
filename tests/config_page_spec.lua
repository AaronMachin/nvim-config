-- lua/floatterm/config_page: a row for every setting, and the keys that change them.

local H = require "test_helpers"
local api = vim.api

local page, settings

local function keys(text)
  api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "x", false)
end

-- The page's line for a label.
local function row(label)
  for _, line in ipairs(page.lines()) do
    if line:sub(2, #label + 1) == label then
      return line
    end
  end
  return nil
end

-- Moves the cursor to the row with `label`.
local function go_to(label)
  -- k stops at the first row (gg would land on the header).
  for _ = 1, 15 do
    keys "k"
  end
  for _ = 1, 20 do
    local line = api.nvim_get_current_line()
    if line:sub(2, #label + 1) == label then
      return
    end
    keys "j"
  end
  error("no row " .. label)
end

describe("settings page", function()
  before_each(function()
    H.isolate()
    page = require "floatterm.config_page"
    settings = require "floatterm.settings"
    H.isolate()
    page.open()
  end)

  after_each(function()
    page.close()
    H.restore()
    H.close_floats()
  end)

  it("has a row for every setting", function()
    local lines = page.lines()
    local count = vim.tbl_count(settings.defaults)
    -- A header and a blank line, then one row per setting.
    assert.equals(count + 2, #lines)
    for _, label in ipairs {
      "Tab bar",
      "Tab bar width",
      "Starting position",
      "Docked sizes",
      "Key hints",
      "Reopen tabs on start",
      "Claude bookmark",
      "Notes side",
      "Notes size",
      "Claude's notes",
      "Claude's notes model",
      "Claude's share",
    } do
      assert.is_not_nil(row(label), "no row for " .. label)
    end
    assert.truthy(row("Docked sizes"):find("large 90%", 1, true))
    assert.truthy(row("Notes size"):find("35%", 1, true))
  end)

  it("changes a choice with l and h, stopping at the ends, and Enter wraps round", function()
    go_to "Tab bar"
    keys "l"
    assert.equals("top", settings.get "tabbar")
    keys "ll"
    assert.equals("off", settings.get "tabbar")
    keys "<CR>"
    assert.equals("left", settings.get "tabbar")
    keys "h"
    assert.equals("left", settings.get "tabbar")
    assert.truthy(row("Tab bar"):find("‹ left ›", 1, true))
    -- Saved straight away.
    assert.equals("left", vim.json.decode(H.read(settings.path)).tabbar)
  end)

  it("steps a number within its bounds", function()
    go_to "Tab bar width"
    keys "l"
    assert.equals(30, settings.get "tabbar_width")
    for _ = 1, 30 do
      keys "l"
    end
    assert.equals(60, settings.get "tabbar_width")
  end)

  it("refuses a typed number outside the bounds rather than changing it", function()
    local messages = H.capture_notify()
    H.answer_input "200"
    go_to "Notes size"
    keys "<CR>"
    assert.equals(0.35, settings.get "notes_share")
    assert.is_not_nil(H.notified(messages, "Notes size must be 15%% to 60%%"))
    H.answer_input "50%"
    keys "<CR>"
    assert.equals(0.5, settings.get "notes_share")
  end)

  it("keeps the large docked size above the small one, Tab picking which", function()
    go_to "Docked sizes"
    for _ = 1, 20 do
      keys "h"
    end
    -- large stops one above small (20%).
    assert.equals(0.21, settings.get("dock_sizes").large)
    keys "<Tab>"
    for _ = 1, 20 do
      keys "l"
    end
    assert.equals(0.20, settings.get("dock_sizes").small)
  end)

  it("closes with q and goes back to the window it came from", function()
    page.close()
    local from = api.nvim_get_current_win()
    page.open()
    assert.is_true(page.is_open())
    assert.is_not.equals(from, api.nvim_get_current_win())
    keys "q"
    assert.is_false(page.is_open())
    assert.equals(from, api.nvim_get_current_win())
  end)
end)
