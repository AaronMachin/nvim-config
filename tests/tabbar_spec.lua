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

    it("opens it out of typing after Ctrl+x, so a click never starts typing then", function()
      local first = H.sleep_tab { label = "first" }
      H.sleep_tab { label = "second" }
      vim.cmd "stopinsert"
      H.flush(50)
      local commands = click_tab "first"
      assert.equals(first, ft.current_buf())
      assert.equals(first, vim.api.nvim_get_current_buf())
      assert.is_false(vim.tbl_contains(commands, "startinsert"))
    end)

    it("opens it typing when clicked from the code, and drops the click's release", function()
      local first = H.sleep_tab { label = "first" }
      H.sleep_tab { label = "second" }
      vim.cmd "stopinsert"
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative == "" then
          vim.api.nvim_set_current_win(win)
        end
      end
      H.flush(50)
      local commands = click_tab "first"
      assert.equals(first, ft.current_buf())
      assert.truthy(vim.tbl_contains(commands, "startinsert"))
      local release = vim.fn.maparg("<LeftRelease>", "n", false, true)
      assert.equals("", release.callback())
      -- Only the one release after a click on the bar.
      assert.equals(vim.keycode "<LeftRelease>", vim.keycode(release.callback()))
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
    it("shows what a tab is first, then its state and folder underneath", function()
      H.sleep_tab { label = "shell" }
      local buf = claude_tab { label = "api", status = "needs_you", title = "✳ Fixing login", note_id = "20261120-pen" }
      -- ✎: your notes have something in them.
      H.write(require("floatterm.notes").paths(ft.record(buf)).mine, "# api\n\ncheck the top bar\n")
      local lines = draw()
      assert.truthy(lines[1]:find "^  %S", lines[1]) -- the shell's command
      assert.truthy(lines[2]:match "^  idle · shell$" or lines[2]:match "^  running · shell$", lines[2])
      assert.equals("", lines[3]) -- a blank line between tabs
      assert.truthy(lines[4]:match "^▶ %S+ Fixing login$", lines[4])
      assert.truthy(lines[5]:match "^▎ ● needs you · %d+s ✎ · api$", lines[5])
      assert.equals(5, #lines)
    end)

    it("shows a Claude tab's folder until it has a summary", function()
      claude_tab { label = "api" }
      local lines = draw()
      assert.truthy(lines[1]:match "^▶ %S+ api$", lines[1])
      assert.equals("▎ ✳ new · api", lines[2])
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
      assert.equals(width, vim.fn.strdisplaywidth(lines[1]))
      assert.truthy(lines[1]:find "…$")
    end)

    it("drops blank lines when the tabs don't fit, then scrolls to the tab you're in", function()
      for i = 1, 14 do
        claude_tab { label = "tab" .. i, status = "done", title = "✳ task " .. i }
      end
      -- 14 tabs of 2 lines with gaps would be 41 lines; the bar has 40.
      local lines = draw()
      assert.equals(28, #lines)
      assert.is_false(vim.tbl_contains(lines, ""))
      assert.truthy(lines[1]:match "^  %S+ task 1$", lines[1])
      assert.truthy(lines[2]:match "^  ✓ done · %d+s · tab1$", lines[2])

      for i = 15, 21 do
        claude_tab { label = "tab" .. i, status = "done", title = "✳ task " .. i }
      end
      -- 21 tabs of 2 lines is 42: every tab keeps both lines and the bar scrolls,
      -- keeping the tab you're in (the last) on screen.
      lines = draw()
      assert.equals(42, #lines)
      assert.truthy(lines[42]:match "^▎ ✓ done · %d+s · tab21$", lines[42])
      local view = api.nvim_win_call(tabbar.window(), function()
        return { top = vim.fn.line "w0", bottom = vim.fn.line "w$" }
      end)
      assert.equals(42, view.bottom)
      assert.is_true(view.top > 1)
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

  describe("decisions waiting", function()
    before_each(function()
      local decisions = require "floatterm.decisions"
      local root = H.tmpdir "decisions"
      H.stub(decisions, "root", root)
      H.stub(decisions, "CHECK_MS", 0)
      decisions.reset()
      for i = 1, 2 do
        H.write(root .. "/app/d" .. i .. ".json", vim.json.encode { session = "s1", state = "open", section = "needs-you" })
      end
    end)

    it("shows ◆ and how many after the state, in the needs-you colour", function()
      claude_tab { label = "api", status = "working", session_id = "s1" }
      claude_tab { label = "other", status = "working", session_id = "s2" }
      local lines = draw()
      assert.truthy(lines[2]:find("◌ working · %d+s ◆ 2 · api"), lines[2])
      assert.is_nil(lines[5]:find("◆", 1, true))
    end)

    it("shows it along the top too", function()
      settings.set("tabbar", "top")
      claude_tab { label = "api", status = "working", session_id = "s1" }
      assert.truthy(draw()[1]:find("◆ 2", 1, true))
    end)
  end)

  describe("marks", function()
    local marks

    before_each(function()
      marks = require "floatterm.marks"
    end)

    -- The highlight on `text` in line `row` of the bar (0-based), or nil.
    local function highlight_on(row, text)
      local buf = api.nvim_win_get_buf(tabbar.window())
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local col = line:find(text, 1, true) - 1
      local found
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
        local d = mark[4]
        if mark[3] <= col and (d.end_col or 0) > col and d.priority == 200 then
          found = d.hl_group
        end
      end
      return found
    end

    it("leads the second line with the label in its colour", function()
      local buf = H.sleep_tab { label = "api" }
      marks.set(buf, "review")
      local lines = draw()
      assert.truthy(lines[2]:find "^▎  review  idle" or lines[2]:find "^▎  review  running", lines[2])
      assert.equals("FloatTermMarkBlue", highlight_on(1, "review"))
    end)

    it("greys a tab marked done all over, both lines kept", function()
      H.sleep_tab { label = "shell" }
      local buf = claude_tab { label = "api", status = "working", title = "✳ Fixing login" }
      marks.toggle_done(buf)
      local lines = draw()
      assert.equals(5, #lines)
      assert.truthy(lines[5]:find "^▎  done  ◌ working", lines[5])
      assert.equals("FloatTermMarkGreen", highlight_on(4, "done"))
      assert.equals("FloatTermMarkedDone", highlight_on(3, "Fixing login"))
      assert.equals("FloatTermMarkedDone", highlight_on(4, "working"))
      -- The other tab isn't greyed.
      assert.is_not.equals("FloatTermMarkedDone", highlight_on(1, "idle") or highlight_on(1, "running"))
      marks.toggle_done(buf)
      assert.is_nil(ft.record(buf).mark)
    end)

    it("gives your own label the same colour every time, cut to 16 characters", function()
      local buf = H.sleep_tab { label = "api" }
      marks.set(buf, "waiting on Sam and the infra team")
      assert.equals("waiting on Sam a", ft.record(buf).mark)
      assert.equals(marks.colour "waiting on Sam a", marks.colour "waiting on Sam a")
      assert.truthy(vim.tbl_contains({ "purple", "cyan", "orange", "yellow" }, marks.colour "waiting on Sam a"))
    end)

    local function press(text)
      api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "x", false)
    end

    it("d in the bar marks the selected tab done, and again takes it off", function()
      local buf = H.sleep_tab { label = "api" }
      tabbar.enter()
      press "d"
      assert.equals("done", ft.record(buf).mark)
      assert.truthy(vim.tbl_contains(tabbar.hint_lines(), "d      not done"))
      press "d"
      assert.is_nil(ft.record(buf).mark)
    end)

    it("t then a key puts that label on, t t takes it off, listing them while it waits", function()
      local buf = H.sleep_tab { label = "api" }
      tabbar.enter()
      local listed
      local real = vim.fn.getcharstr
      H.stub(vim.fn, "getcharstr", function()
        listed = tabbar.hint_lines()
        return real()
      end)
      press "tr"
      assert.equals("review", ft.record(buf).mark)
      for _, line in ipairs { "t d    done", "t r    review", "t b    blocked", "t p    parked", "t e    your own label" } do
        assert.truthy(vim.tbl_contains(listed, line), line)
      end
      -- Back to the usual keys after.
      assert.truthy(vim.tbl_contains(tabbar.hint_lines(), "t      put a label on it"))
      press "tt"
      assert.is_nil(ft.record(buf).mark)
    end)

    it("t e asks for your own label and offers it next time", function()
      H.stub(marks, "path", H.tmpdir "marks" .. "/marks.json")
      local buf = H.sleep_tab { label = "api" }
      tabbar.enter()
      H.answer_input "waiting on Sam"
      press "te"
      assert.equals("waiting on Sam", ft.record(buf).mark)
      assert.same({ "waiting on Sam" }, marks.recent())
      assert.same({ "waiting on Sam" }, marks.complete "wait")
      assert.same({}, marks.complete "zz")
    end)

    it("takes its labels and keys from the settings", function()
      settings.set("marks", { { key = "s", word = "shipped", colour = "green" } })
      local buf = H.sleep_tab { label = "api" }
      tabbar.enter()
      press "ts"
      assert.equals("shipped", ft.record(buf).mark)
      assert.equals("green", marks.colour "shipped")
    end)

    it("goes after the emoji along the top", function()
      settings.set("tabbar", "top")
      local buf = H.sleep_tab { label = "shell" }
      marks.set(buf, "parked")
      local line = draw()[1]
      assert.truthy(line:find(ft.record(buf).emoji .. "  parked  $ shell", 1, true), line)
    end)
  end)

  describe("Claude's summary under the bar", function()
    local notes

    before_each(function()
      notes = require "floatterm.notes"
    end)

    -- A Claude tab with a summary whose title is `title`.
    local function summarised(label, title)
      local buf = claude_tab { label = label, status = "working", note_id = "20261120-" .. label }
      local paths = notes.paths(ft.record(buf))
      H.write(paths.claude_json, vim.json.encode { title = title, now = "Task 1", tasks = { { name = "Schema", state = "in_progress" } } })
      return buf
    end

    local function summary_text()
      local win = tabbar.summary_window()
      if not win then
        return nil
      end
      return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n")
    end

    it("shows the tab you're in below the tab list, in the same box", function()
      summarised("api", "SD-1 · Login fix")
      tabbar.redraw()
      assert.truthy(summary_text(), "no summary")
      assert.truthy(summary_text():find("Login fix", 1, true), summary_text())
      local bar = api.nvim_win_get_config(tabbar.window())
      local below = api.nvim_win_get_config(tabbar.summary_window())
      assert.equals(ft.layout().tabbar.height, bar.height + below.height + 4)
      assert.is_true(below.width <= 28)
    end)

    it("shows nothing for a shell tab or a Claude tab without one yet", function()
      H.sleep_tab { label = "shell" }
      tabbar.redraw()
      assert.is_nil(tabbar.summary_window())
      claude_tab { label = "fresh", status = "working", note_id = "20261120-fresh" }
      tabbar.redraw()
      assert.is_nil(tabbar.summary_window())
    end)

    it("follows the selection in the bar, then goes back to the tab you're in", function()
      local first = summarised("one", "First piece")
      summarised("two", "Second piece")
      tabbar.redraw()
      assert.truthy(summary_text():find("Second piece", 1, true))
      tabbar.enter()
      vim.api.nvim_feedkeys(vim.keycode "k", "x", false)
      assert.truthy(summary_text():find("First piece", 1, true), summary_text())
      vim.api.nvim_set_current_win(ft.window())
      H.wait(1000, function()
        return summary_text() and summary_text():find("Second piece", 1, true)
      end, "didn't go back to the current tab")
      -- Switching tab with the keys changes it too.
      ft.focus_buf(first)
      tabbar.redraw()
      assert.truthy(summary_text():find("First piece", 1, true))
    end)

    it("isn't drawn under the bar with the setting elsewhere, or with the bar along the top", function()
      summarised("api", "SD-1 · Login fix")
      settings.set("claude_summary", "asked")
      tabbar.redraw()
      assert.is_nil(tabbar.summary_window())
      settings.set("claude_summary", "bar")
      settings.set("tabbar", "top")
      tabbar.redraw()
      assert.is_nil(tabbar.summary_window())
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
      -- The second row is Claude's summary, empty for one without a summary.
      assert.equals(2, #lines)
      assert.equals("", vim.trim(lines[2]))
      assert.truthy(lines[1]:find("$ shell", 1, true))
      assert.truthy(lines[1]:find(" │ ▶ " .. ft.record(ft.tabs()[2].buf).emoji .. " ✓ done", 1, true))
      -- Each tab starts with its emoji.
      assert.truthy(lines[1]:find(ft.record(ft.tabs()[1].buf).emoji .. " $ shell", 1, true))
      assert.truthy(lines[1]:find("Tidy", 1, true))
      assert.truthy(lines[1]:find("api", 1, true))
    end)

    it("puts Claude's summary of the tab showing on the second row", function()
      local notes = require "floatterm.notes"
      local buf = claude_tab { label = "api", status = "working", note_id = "20261120-top" }
      H.write(
        notes.paths(ft.record(buf)).claude_json,
        vim.json.encode {
          title = "SD-1 · Login fix",
          now = "Task 2",
          tasks = { { name = "Schema", state = "done" }, { name = "Model", state = "in_progress" } },
          links = { { title = "PR #9 console", url = "https://x/pull/9", note = "Opened" } },
        }
      )
      local lines = draw()
      for _, text in ipairs { "SD-1 · Login fix", "◌ Task 2", "75%", "▸ Model", "PR #9 console" } do
        assert.truthy(lines[2]:find(text, 1, true), text .. " in " .. lines[2])
      end
      assert.is_true(vim.fn.strdisplaywidth(lines[2]) <= 196)
    end)

    it("has one row with Claude's summary shown elsewhere", function()
      settings.set("claude_summary", "asked")
      H.sleep_tab { label = "shell" }
      assert.equals(1, #draw())
    end)

    it("shortens summaries, then scrolls to keep the current tab in view", function()
      for i = 1, 4 do
        claude_tab { label = "t" .. i, status = "working", title = "✳ " .. string.rep("summary" .. i .. " ", 8) }
      end
      local line = draw()[1]
      assert.is_true(vim.fn.strdisplaywidth(line) <= 196)
      -- Folders go before summaries are cut.
      assert.is_nil(line:find("t1", 1, true))
      assert.truthy(line:find("…", 1, true))

      for i = 5, 20 do
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

  it("adds ◆ to a Claude tab with decisions waiting for you", function()
    local decisions = require "floatterm.decisions"
    local root = H.tmpdir "decisions"
    H.stub(decisions, "root", root)
    H.stub(decisions, "CHECK_MS", 0)
    decisions.reset()
    H.write(root .. "/app/d1.json", vim.json.encode { session = "s1", state = "open", section = "needs-you" })
    claude_tab { status = "working", session_id = "s1" }
    claude_tab { status = "working", session_id = "s2" }
    bookmark.redraw()
    assert.equals(" ◌◆ ◌ ", bookmark.text())
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
