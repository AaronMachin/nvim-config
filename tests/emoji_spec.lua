-- lua/floatterm/emoji: an emoji per tab in the tab bar, random and never shared with
-- another tab.

local H = require "test_helpers"

local ft, emoji, tabbar

describe("emoji", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    emoji = require "floatterm.emoji"
    tabbar = require "floatterm.tabbar"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  it("gives each tab an emoji from the set that no other tab has", function()
    local bufs = { H.sleep_tab(), H.sleep_tab(), H.sleep_tab() }
    tabbar.redraw()
    local seen = {}
    for _, buf in ipairs(bufs) do
      local record = ft.record(buf)
      assert.truthy(vim.tbl_contains(emoji.SET, record.emoji), record.emoji)
      assert.is_nil(seen[record.emoji])
      seen[record.emoji] = true
    end
    -- It leads the shell's first line in the bar.
    assert.truthy(tabbar.lines()[1]:find(ft.record(bufs[1]).emoji, 1, true))
  end)

  it("keeps a tab's emoji once it has one", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    local first = ft.record(buf).emoji
    for _ = 1, 5 do
      emoji.ensure_all()
    end
    assert.equals(first, ft.record(buf).emoji)
  end)

  it("gives a Claude tab its emoji straight away", function()
    local _, buf = ft.new_tab({ "sleep", "300" }, { kind = "claude" })
    tabbar.redraw()
    local record = ft.record(buf)
    assert.truthy(vim.tbl_contains(emoji.SET, record.emoji), record.emoji)
    assert.equals(record.emoji, emoji.glyph(record))
  end)

  it("gives a tab sharing its emoji with a tab above it a new one", function()
    local first, second, third = H.sleep_tab(), H.sleep_tab(), H.sleep_tab()
    tabbar.redraw()
    ft.update(second, { emoji = ft.record(first).emoji })
    ft.update(third, { emoji = ft.record(first).emoji })
    local kept = ft.record(first).emoji
    emoji.ensure_all()
    assert.equals(kept, ft.record(first).emoji)
    local seen = {}
    for _, buf in ipairs { first, second, third } do
      local e = ft.record(buf).emoji
      assert.is_nil(seen[e], e)
      seen[e] = true
    end
  end)

  it("keeps an emoji from outside the set while no other tab has it", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    ft.update(buf, { emoji = "🔐" })
    emoji.ensure_all()
    assert.equals("🔐", ft.record(buf).emoji)
  end)

  it("has no repeats in the set, and each is one character two columns wide", function()
    local seen = {}
    for _, e in ipairs(emoji.SET) do
      assert.is_nil(seen[e], e)
      seen[e] = true
      assert.equals(1, vim.fn.strchars(e), e)
      assert.equals(2, vim.fn.strdisplaywidth(e), e)
    end
  end)

  it("reuses the set once every emoji in it is taken", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    local record = ft.record(buf)
    local others = {}
    for i, e in ipairs(emoji.SET) do
      others[i] = { emoji = e }
    end
    H.stub(ft, "tabs", function()
      return vim.list_extend({ record }, others)
    end)
    assert.truthy(vim.tbl_contains(emoji.SET, emoji.random(record)))
  end)
end)
