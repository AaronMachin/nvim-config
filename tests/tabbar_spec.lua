-- lua/floatterm/tabbar (the lines it draws and how it fits them) and
-- lua/floatterm/bookmark.

local H = require "test_helpers"

local ft, tabbar, settings

local function claude_tab(fields)
  local buf = H.sleep_tab { kind = "claude", label = fields.label }
  fields.label = nil
  ft.update(buf, fields)
  return buf
end

local function draw()
  tabbar.redraw()
  return tabbar.lines()
end

describe("tab bar", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    tabbar = require "floatterm.tabbar"
    settings = require "floatterm.settings"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  describe("what a tab shows", function()
    it("gives a Claude tab with no status the 'new' state", function()
      assert.equals("new", tabbar.state({}).word)
      assert.equals("●", tabbar.state({ status = "needs_you" }).glyph)
    end)

    it("takes Claude's title without its spinner, else the last prompt", function()
      assert.equals("Fixing the login", tabbar.summary { title = "✳ Fixing the login" })
      assert.equals("Fixing the login", tabbar.summary { title = "⠂ Fixing the login" })
      -- Claude's own name before it has a task, a terminal's default title and the
      -- shell's title don't count.
      assert.is_nil(tabbar.summary { title = "✳ Claude Code" })
      assert.is_nil(tabbar.summary { title = "term://~//123:claude" })
      assert.equals(
        "first line",
        tabbar.summary {
          title = "me@host:~/app",
          shell_title = "me@host:~/app",
          last_prompt = "first line\nsecond",
        }
      )
    end)
  end)

  describe("down the left", function()
    it("shows state, summary and folder for Claude, folder for a shell, and marks the current tab", function()
      H.sleep_tab { label = "shell" }
      claude_tab { label = "api", status = "needs_you", title = "✳ Fixing login", notes_on = true }
      local lines = draw()
      assert.equals("  $ shell", lines[1])
      assert.equals("", lines[3]) -- a blank line between tabs
      assert.truthy(lines[4]:match "^▶ ● needs you · %d+s ✎$", lines[4])
      assert.equals("  Fixing login", lines[5])
      assert.equals("  ✳ api", lines[6])
    end)

    it("cuts a long summary to the bar's width with …", function()
      settings.set("tabbar_width", 20)
      claude_tab { label = "api", status = "working", title = "✳ " .. string.rep("long words ", 6) }
      local lines = draw()
      local width = 20 - 2 -- inside the border
      assert.equals(width, vim.fn.strdisplaywidth(lines[2]))
      assert.truthy(lines[2]:find "…$")
    end)

    it("drops blank lines first, then Claude folders, when the tabs don't fit", function()
      for i = 1, 12 do
        claude_tab { label = "tab" .. i, status = "done", title = "✳ task " .. i }
      end
      -- 12 tabs of 3 lines with gaps would be 47 lines; the bar has 40.
      local lines = draw()
      assert.equals(36, #lines)
      assert.is_false(vim.tbl_contains(lines, ""))
      assert.equals("  ✳ tab1", lines[3])

      for i = 13, 14 do
        claude_tab { label = "tab" .. i, status = "done", title = "✳ task " .. i }
      end
      lines = draw()
      assert.equals(28, #lines)
      for _, line in ipairs(lines) do
        assert.is_nil(line:find("✳ tab", 1, true))
      end
      assert.equals("  task 1", lines[2])
    end)

    it("closes when the float hides and is off with the setting", function()
      H.sleep_tab()
      assert.is_true(#draw() > 0)
      settings.set("tabbar", "off")
      assert.same({}, draw())
      settings.set("tabbar", "left")
      ft.hide()
      assert.same({}, draw())
    end)
  end)

  describe("along the top", function()
    before_each(function()
      settings.set("tabbar", "top")
    end)

    it("puts every tab on one line with separators", function()
      H.sleep_tab { label = "shell" }
      claude_tab { label = "api", status = "done", title = "✳ Tidy" }
      local lines = draw()
      assert.equals(1, #lines)
      assert.truthy(lines[1]:find("$ shell", 1, true))
      assert.truthy(lines[1]:find(" │ ▶ ✓ done", 1, true))
      assert.truthy(lines[1]:find("Tidy", 1, true))
      assert.truthy(lines[1]:find("api", 1, true))
    end)

    it("shortens summaries, then scrolls to keep the current tab in view", function()
      for i = 1, 6 do
        claude_tab { label = "t" .. i, status = "working", title = "✳ " .. string.rep("summary" .. i .. " ", 8) }
      end
      local line = draw()[1]
      assert.is_true(vim.fn.strdisplaywidth(line) <= 196)
      -- Folders go before summaries are cut.
      assert.is_nil(line:find("t1", 1, true))
      assert.truthy(line:find("…", 1, true))

      for i = 7, 20 do
        claude_tab { label = "t" .. i, status = "working", title = "✳ task" }
      end
      line = draw()[1]
      -- The current (last) tab shows, with ‹ for the tabs before.
      assert.truthy(line:find "^‹ ")
      assert.truthy(line:find("▶", 1, true))
    end)
  end)
end)

describe("bookmark", function()
  local bookmark

  before_each(function()
    H.isolate()
    ft = require "floatterm"
    bookmark = require "floatterm.bookmark"
    settings = require "floatterm.settings"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    bookmark.redraw()
    H.restore()
    H.close_floats()
  end)

  it("shows a mark per Claude tab in tab order, and nothing for shells", function()
    H.sleep_tab()
    assert.is_nil((function()
      bookmark.redraw()
      return bookmark.text()
    end)())
    claude_tab { status = "needs_you" }
    claude_tab { status = "working" }
    claude_tab {}
    bookmark.redraw()
    assert.equals(" ● ◌ ✳ ", bookmark.text())
  end)

  it("hides with the setting", function()
    claude_tab { status = "done" }
    bookmark.toggle()
    bookmark.redraw()
    assert.is_nil(bookmark.text())
    assert.is_false(settings.get "bookmark")
    bookmark.toggle()
    bookmark.redraw()
    assert.equals(" ✓ ", bookmark.text())
  end)
end)
