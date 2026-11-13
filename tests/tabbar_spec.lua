-- lua/floatterm/tabbar (the lines it draws and how it fits them) and
-- lua/floatterm/bookmark.

local H = require "test_helpers"

local api = vim.api
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

  describe("a click on a tab", function()
    -- Headless nvim has no screen to click on, so the click's position is given as nvim
    -- would report it, at the first cell of the tab's line in the bar. Typing mode
    -- doesn't show in a headless run, so what's checked is whether the click asked
    -- for it.
    local function click_tab(label)
      tabbar.redraw()
      local win = tabbar.window()
      local row
      for i, line in ipairs(tabbar.lines()) do
        if line:find(label, 1, true) then
          row = i
        end
      end
      local pos = vim.api.nvim_win_get_position(win)
      H.stub(vim.fn, "getmousepos", function()
        return { screenrow = pos[1] + row + 1, screencol = pos[2] + 3, winid = win, line = row, column = 2 }
      end)
      local commands = {}
      local cmd = vim.cmd
      H.stub(vim, "cmd", function(command)
        table.insert(commands, command)
        return cmd(command)
      end)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "x", false)
      H.flush(50)
      vim.cmd = cmd
      return commands
    end

    before_each(function()
      tabbar.setup()
      settings.set("tabbar", "left")
    end)

    it("opens it in normal mode when you weren't typing, so a click never starts typing", function()
      local first = H.sleep_tab { label = "first" }
      H.sleep_tab { label = "second" }
      vim.cmd "stopinsert"
      H.flush(50)
      local commands = click_tab "first"
      assert.equals(first, ft.current_buf())
      assert.equals(first, vim.api.nvim_get_current_buf())
      assert.is_false(vim.tbl_contains(commands, "startinsert"))
    end)
  end)

  describe("the key hints", function()
    local function press(text)
      api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "x", false)
    end

    it("show beside the selected tab while in the bar, follow it, and go on Esc", function()
      local lead = claude_tab { label = "lead", status = "needs_you", title = "Plan workstreams" }
      local child = H.sleep_tab { label = "child" }
      require("floatterm.groups").set_parent(child, lead)
      H.sleep_tab { label = "solo" }
      ft.focus_buf(lead)
      assert.same({}, tabbar.hint_lines())
      tabbar.enter()
      local lines = tabbar.hint_lines()
      assert.truthy(lines[1]:find "^● needs you · .*Plan workstreams$", lines[1])
      assert.equals("Claude tab · 1 tab under it", lines[2])
      assert.truthy(vim.tbl_contains(lines, "Enter  open it"))
      assert.truthy(vim.tbl_contains(lines, "za     fold its 1 tab away"))
      assert.truthy(vim.tbl_contains(lines, "x      close (asks first)"))
      -- Beside the first line of the tab it's on.
      local first_row = api.nvim_win_get_config(tabbar.hint_window()).row
      press "j"
      lines = tabbar.hint_lines()
      assert.equals("$ child", lines[1])
      assert.equals("Terminal · under lead", lines[2])
      assert.is_false(vim.tbl_contains(lines, "za     fold its 1 tab away"))
      assert.truthy(vim.tbl_contains(lines, "x      close"))
      assert.is_true(api.nvim_win_get_config(tabbar.hint_window()).row > first_row)
      press "<Esc>"
      vim.cmd "stopinsert"
      assert.same({}, tabbar.hint_lines())
    end)

    it("cut a long command to fit, and c shows it in full until the selection moves", function()
      local long = "podman run --rm -it --name hubdash-local " .. string.rep("-v /var/home/amachin/x:/x:z ", 8)
      local buf = H.sleep_tab { label = "todo" }
      H.sleep_tab { label = "other" }
      ft.update(buf, { command = long })
      ft.focus_buf(buf)
      tabbar.enter()
      local lines = tabbar.hint_lines()
      for _, line in ipairs(lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 58, line)
      end
      assert.truthy(lines[2]:find "^podman run .*…$", lines[2])
      assert.truthy(vim.tbl_contains(lines, "c      show the full command"))

      press "c"
      lines = tabbar.hint_lines()
      local shown = {}
      for n = 2, #lines do
        if lines[n] == "running" then
          break
        end
        table.insert(shown, lines[n])
      end
      -- Wrapped lines put back together are the whole command (the lines come back
      -- trimmed, so a space at a wrap is lost).
      local function squash(text)
        return (text:gsub("%s", ""))
      end
      assert.is_true(#shown > 1)
      assert.equals(squash(long), squash(table.concat(shown, "")))
      assert.truthy(vim.tbl_contains(lines, "c      hide the full command"))

      press "j"
      press "k"
      assert.truthy(tabbar.hint_lines()[2]:find "…$")
    end)

    it("say H / L and h/l along the top", function()
      settings.set("tabbar", "top")
      H.sleep_tab { label = "one" }
      tabbar.enter()
      local lines = tabbar.hint_lines()
      assert.truthy(vim.tbl_contains(lines, "H / L  move earlier / later"), table.concat(lines, "\n"))
      assert.equals("h/l move · 1-9 open · Esc back", lines[#lines])
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
      assert.equals("▎ Fixing login", lines[5])
      assert.equals("▎ ✳ api", lines[6])
    end)

    it("gives every line of the current tab a full-width background and an edge", function()
      H.sleep_tab { label = "shell" }
      claude_tab { label = "api", status = "working", title = "✳ Fixing login" }
      local lines = draw()
      local buf = api.nvim_win_get_buf(tabbar.window())
      local ns = api.nvim_get_namespaces().floatterm_tabbar
      local marked = {}
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        local details = mark[4]
        if details.hl_group == "FloatTermCurrent" then
          assert.is_true(details.hl_eol)
          for line = mark[2], details.end_row - 1 do
            marked[line + 1] = true
          end
        end
      end
      -- The shell (lines 1-2) and the gap (3) aren't marked; the Claude tab's lines are.
      assert.is_nil(marked[1])
      assert.is_nil(marked[3])
      for n = 4, #lines do
        assert.is_true(marked[n], "line " .. n)
      end
      assert.truthy(lines[4]:find "^▶ ")
      for n = 5, #lines do
        assert.truthy(lines[n]:find "^▎ ", lines[n])
      end
      assert.is_not_nil(api.nvim_get_hl(0, { name = "FloatTermCurrent" }).bg)
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
