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

  it("gives a tab whose emoji isn't in the set any more a new one", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    ft.update(buf, { emoji = "🪁" })
    emoji.ensure_all()
    assert.truthy(vim.tbl_contains(emoji.SET, ft.record(buf).emoji))
  end)

  it("has none of the emoji fonts from before 2019 lack", function()
    for _, newer in ipairs { "🪁", "🪐", "🧊", "🪴", "🦩", "🪀", "🛼", "🪄", "🪸", "🦦", "🦥" } do
      assert.is_false(vim.tbl_contains(emoji.SET, newer), newer)
    end
  end)

  describe("as symbols", function()
    local settings

    before_each(function()
      settings = require "floatterm.settings"
      settings.set("tab_icons", "symbols")
    end)

    it("shows a coloured shape two columns wide, never two the same", function()
      local bufs = {}
      for i = 1, 12 do
        bufs[i] = H.sleep_tab()
      end
      emoji.ensure_all()
      local seen = {}
      for _, buf in ipairs(bufs) do
        local icon = emoji.icon(ft.record(buf))
        assert.equals(2, vim.fn.strdisplaywidth(icon[1]))
        assert.truthy(icon[2]:match "^FloatTermIcon%d$", icon[2])
        local look = icon[1] .. icon[2]
        assert.is_nil(seen[look], look)
        seen[look] = true
      end
    end)

    it("draws it in the tab bar in place of the emoji", function()
      local buf = H.sleep_tab { label = "api" }
      tabbar.redraw()
      local shape = emoji.glyph(ft.record(buf))
      assert.truthy(vim.tbl_contains(emoji.SHAPES, shape))
      assert.truthy(tabbar.lines()[1]:find(shape, 1, true), tabbar.lines()[1])
    end)
  end)

  describe("the font check on Linux", function()
    local messages

    before_each(function()
      messages = H.capture_notify()
      H.stub(emoji, "is_linux", function()
        return true
      end)
    end)

    local function fonts(list)
      H.stub(emoji, "list_fonts", function(callback)
        callback(list)
      end)
    end

    it("says so when there's no colour emoji font", function()
      fonts "DejaVu Sans Mono\nNoto Emoji\n"
      emoji.check_font()
      H.flush(20)
      assert.is_not_nil(H.notified(messages, "no colour emoji font"))
    end)

    it("says nothing with one, with symbols, or off Linux", function()
      fonts "DejaVu Sans Mono\nNoto Color Emoji\n"
      emoji.check_font()
      require("floatterm.settings").set("tab_icons", "symbols")
      fonts "DejaVu Sans Mono\n"
      emoji.check_font()
      require("floatterm.settings").set("tab_icons", "emoji")
      H.stub(emoji, "is_linux", function()
        return false
      end)
      emoji.check_font()
      H.flush(20)
      assert.is_nil(H.notified(messages, "no colour emoji font"))
    end)
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
