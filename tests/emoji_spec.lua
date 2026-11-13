-- lua/floatterm/emoji: an emoji per tab in the tab bar. Shell tabs get a random one no
-- other tab has, Claude tabs show ✳ until one is picked for them as a Claude tab.

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

  it("gives each shell tab an emoji from the set that no other tab has", function()
    local bufs = { H.sleep_tab(), H.sleep_tab(), H.sleep_tab() }
    tabbar.redraw()
    local seen = {}
    for _, buf in ipairs(bufs) do
      local record = ft.record(buf)
      assert.truthy(vim.tbl_contains(emoji.SET, record.emoji), record.emoji)
      assert.equals("shell", record.emoji_for)
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

  it("shows ✳ for a Claude tab until it has an emoji picked as a Claude tab", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    ft.update(buf, { kind = "claude" })
    assert.equals("✳", emoji.glyph(ft.record(buf)))
    ft.update(buf, { emoji = "🔐", emoji_for = "claude" })
    assert.equals("🔐", emoji.glyph(ft.record(buf)))
    -- Back to a shell, it's still the same piece of work.
    ft.update(buf, { kind = "shell" })
    emoji.ensure_all()
    assert.equals("🔐", emoji.glyph(ft.record(buf)))
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
