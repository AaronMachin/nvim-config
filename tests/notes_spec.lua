-- lua/floatterm/notes: where notes live, switching them on and off, the captures,
-- never deleting notes for you, Claude's pop-up, Claude's dossier in the pane and the
-- large view (links, folds and their state), sharing with another nvim, and the
-- picker's filtering.

local H = require "test_helpers"
local api = vim.api

local ft, notes, paths

local function lines_of(path)
  return vim.split(vim.trim(H.read(path) or ""), "\n", { plain = true })
end

local function keys(text, mode)
  api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), mode or "x", false)
end

describe("notes", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    notes = require "floatterm.notes"
    notes.setup()
    paths = H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
    pcall(vim.cmd, "stopinsert")
  end)

  it("keeps notes in .nvim/fterm/notes of the folder nvim started in", function()
    assert.equals(paths.start .. "/.nvim/fterm/notes", notes.dir())
    assert.is_nil(notes.paths { note_id = nil })
    local p = notes.paths { note_id = "20261029-abcd" }
    assert.equals(notes.dir() .. "/20261029-abcd.md", p.mine)
    assert.equals(notes.dir() .. "/20261029-abcd.claude.md", p.claude)
    assert.equals(notes.dir() .. "/20261029-abcd.claude.json", p.claude_json)
  end)

  describe("on and off", function()
    it("gives a tab notes with a heading, shows the pane, and hides it again keeping the file", function()
      local buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      local record = ft.record(buf)
      assert.truthy(record.note_id:match "^%d%d%d%d%d%d%d%d%-%w%w%w%w$")
      assert.is_true(record.notes_on)
      local mine = notes.paths(record).mine
      assert.same({ "# api" }, lines_of(mine))
      notes.redraw()
      local state = notes.state()
      assert.is_not_nil(state.mine)
      assert.is_true(api.nvim_win_is_valid(state.mine))
      assert.is_true(vim.wo[state.mine].winfixbuf)

      notes.set(buf, false)
      notes.redraw()
      assert.is_nil(notes.state().mine)
      assert.is_true(H.exists(mine))
      -- Back on: the same notes.
      local id = record.note_id
      notes.set(buf, true)
      assert.equals(id, ft.record(buf).note_id)
    end)

    it("shows the notes over the terminal in the box placement with Ctrl+Shift+e", function()
      local buf = H.sleep_tab()
      ft.switch_mode()
      notes.toggle_focus()
      assert.is_true(ft.record(buf).notes_on)
      local state = notes.state()
      assert.is_true(state.overlay)
      assert.equals(state.mine, api.nvim_get_current_win())
      notes.back()
      assert.is_false(notes.state().overlay)
      assert.equals(ft.window(), api.nvim_get_current_win())
      ft.switch_mode()
    end)
  end)

  describe("captures", function()
    it("Y in a terminal tab adds the selection, wrapped lines joined, with where it came from", function()
      local _, buf = ft.new_tab({ "sh", "-c", "echo first; echo second; sleep 300" }, { label = "logs" })
      H.wait(3000, function()
        return api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "second"
      end)
      keys "<C-\\><C-n>"
      vim.cmd "normal! ggVj"
      notes.capture_terminal()
      local record = ft.record(buf)
      assert.is_true(record.notes_on)
      local lines = lines_of(notes.paths(record).mine)
      assert.equals("# logs", lines[1])
      assert.equals("", lines[2])
      assert.truthy(lines[3]:match "^### %d%d:%d%d · logs$", lines[3])
      assert.same({ "```", "first", "second", "```" }, vim.list_slice(lines, 4, 7))
    end)

    it("<leader>o y in code adds the selection with its file and lines, in its language", function()
      local buf = H.sleep_tab { label = "api" }
      H.edit(paths.start .. "/src/thing.lua", { "local a = 1", "local b = 2", "local c = 3" })
      vim.bo.filetype = "lua"
      vim.cmd "normal! 2GVj"
      H.capture_notify()
      notes.capture()
      local lines = lines_of(notes.paths(ft.record(buf)).mine)
      assert.truthy(lines[3]:match "^### %d%d:%d%d · src/thing.lua:2%-3$", lines[3])
      assert.same({ "```lua", "local b = 2", "local c = 3", "```" }, vim.list_slice(lines, 4, 7))
    end)

    it("uses a longer fence when the text has one of its own", function()
      local buf = H.sleep_tab()
      H.edit(paths.start .. "/README.md", { "```sh", "make", "```" })
      vim.cmd "normal! ggVG"
      H.capture_notify()
      notes.capture()
      local lines = lines_of(notes.paths(ft.record(buf)).mine)
      assert.truthy(lines[4]:match "^````")
      assert.equals("````", lines[#lines])
    end)

    it("<leader>o a adds one-line notes as one list", function()
      local buf = H.sleep_tab { label = "api" }
      H.answer_input("first thought", "second thought")
      notes.add_note()
      notes.add_note()
      local lines = lines_of(notes.paths(ft.record(buf)).mine)
      assert.equals(4, #lines)
      assert.truthy(lines[3]:match "^%- %d%d:%d%d first thought$")
      assert.truthy(lines[4]:match "^%- %d%d:%d%d second thought$")
    end)
  end)

  it("has an old-format Claude sheet (no .json) rewritten once when it's shown", function()
    local cn = require "floatterm.claude_notes"
    local asked = {}
    local real = cn.upgrade
    cn.upgrade = function(record)
      table.insert(asked, record.note_id)
    end
    local buf = H.sleep_tab { label = "api", kind = "claude" }
    ft.update(buf, { transcript_path = paths.start .. "/t.jsonl" })
    notes.set(buf, true)
    local p = notes.paths(ft.record(buf))
    H.write(p.claude, "## Now\n- old shape\n")
    ft.toggle()
    ft.toggle()
    notes.redraw()
    H.wait(2000, function()
      return #asked > 0
    end)
    notes.redraw()
    H.flush(100)
    cn.upgrade = real
    assert.same({ ft.record(buf).note_id }, asked)
  end)

  describe("never deleted for you", function()
    local function close(buf)
      ft.close_tab(buf)
      H.wait(3000, function()
        return ft.record(buf) == nil
      end)
      H.flush(50)
    end

    it("keeps a note with only its heading when its tab closes, notes go off, or the tab takes other notes", function()
      local buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      local closed = notes.paths(ft.record(buf)).mine
      close(buf)
      assert.is_true(H.exists(closed))

      buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      local off = notes.paths(ft.record(buf)).mine
      notes.set(buf, false)
      assert.is_true(H.exists(off))

      notes.set(buf, true)
      local before = notes.paths(ft.record(buf)).mine
      H.write(notes.dir() .. "/20261029-othr.md", "# other\n\nsomething\n")
      notes.attach(buf, "20261029-othr")
      assert.is_true(H.exists(before))
    end)

    it("leaves notes with nothing in them out of the picker", function()
      local dir = notes.dir()
      vim.fn.mkdir(dir, "p")
      H.write(dir .. "/20261029-head.md", "# api\n\n")
      H.write(dir .. "/20261029-blnk.md", "\n")
      H.write(dir .. "/20261029-mtcl.md", "# api\n")
      H.write(dir .. "/20261029-mtcl.claude.md", "")
      H.write(dir .. "/20261029-text.md", "# api\n\nremember this\n")
      H.write(dir .. "/20261029-clmd.md", "# api\n")
      H.write(dir .. "/20261029-clmd.claude.md", "summary\n")
      H.write(dir .. "/20261029-cljs.md", "# api\n")
      H.write(dir .. "/20261029-cljs.claude.json", vim.json.encode { summary = "s" })
      local captured
      H.stub(require "telescope.pickers", "new", function(_, opts)
        captured = opts
        return { find = function() end }
      end)
      notes.pick()
      local ids = {}
      for _, note in ipairs(captured.finder.results) do
        table.insert(ids, note.value.id)
      end
      table.sort(ids)
      assert.same({ "20261029-cljs", "20261029-clmd", "20261029-text" }, ids)
    end)
  end)

  describe("captures into notes another nvim changed", function()
    local buf, mine, path

    -- Another nvim's save: new text with an mtime a little ahead, so it counts as a
    -- change without waiting a second.
    local function other_save(text)
      H.write(path, text)
      local later = os.time() + 5
      vim.uv.fs_utime(path, later, later)
    end

    before_each(function()
      buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      notes.redraw()
      path = notes.paths(ft.record(buf)).mine
      mine = vim.fn.bufnr(path)
    end)

    it("reloads first, so the capture goes after what the other nvim saved", function()
      other_save "# api\n\nfrom the other nvim\n"
      H.answer_input "mine"
      notes.add_note()
      local lines = lines_of(path)
      assert.equals("from the other nvim", lines[3])
      assert.truthy(lines[#lines]:match "^%- %d%d:%d%d mine$")
      assert.same(lines, vim.split(vim.trim(table.concat(api.nvim_buf_get_lines(mine, 0, -1, false), "\n")), "\n"))
      assert.is_false(vim.bo[mine].modified)
    end)

    it("with unsaved typing here, keeps both and adds the capture at the end", function()
      api.nvim_buf_set_lines(mine, -1, -1, false, { "typed here" })
      assert.is_true(vim.bo[mine].modified)
      other_save "# api\n\nfrom the other nvim\n"
      H.edit(paths.start .. "/code.lua", { "local x = 1" })
      H.capture_notify()
      notes.capture()
      local text = H.read(path)
      assert.truthy(text:find("from the other nvim", 1, true))
      assert.truthy(text:find("typed here", 1, true))
      assert.truthy(text:find("local x = 1", 1, true))
      assert.truthy(text:find("from the other nvim", 1, true) < text:find("local x = 1", 1, true))
      assert.is_false(vim.bo[mine].modified)
    end)
  end)

  describe("Claude's sheet from another nvim", function()
    local buf, record, claude_win

    local function sheet_text()
      return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(notes.state().claude), 0, -1, false), "\n")
    end

    local function write_sheet(summary)
      local p = notes.paths(record)
      H.write(p.claude_json, vim.json.encode { summary = summary })
      local later = os.time() + 5
      vim.uv.fs_utime(p.claude_json, later, later)
    end

    before_each(function()
      buf = H.sleep_tab { label = "api", kind = "claude" }
      notes.set(buf, true)
      record = ft.record(buf)
      H.write(notes.paths(record).claude_json, vim.json.encode { summary = "first sheet" })
      notes.redraw()
      claude_win = notes.state().claude
    end)

    it("draws the new sheet on the next redraw without being told", function()
      assert.truthy(sheet_text():find("first sheet", 1, true))
      write_sheet "second sheet"
      notes.redraw()
      assert.truthy(sheet_text():find("second sheet", 1, true))
      assert.is_true(api.nvim_win_is_valid(claude_win))
    end)

    it("picks it up on its own while the pane shows", function()
      write_sheet "third sheet"
      H.wait(4000, function()
        return sheet_text():find("third sheet", 1, true) ~= nil
      end, "the pane didn't pick up the new sheet")
    end)
  end)

  describe("reading files that aren't", function()
    it("reads a .claude.md that's a folder as empty", function()
      vim.fn.mkdir(notes.dir() .. "/20261029-fold.claude.md", "p")
      local summary, tags = notes.claude_summary "20261029-fold"
      assert.equals("", summary)
      assert.same({}, tags)
      assert.same({ lines = {} }, notes.claude_sheet "20261029-fold")
    end)
  end)

  describe("Claude's notes pop-up", function()
    local buf, record

    before_each(function()
      buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      record = ft.record(buf)
      H.write(notes.paths(record).claude, "# Summary of chat\nFixing login\n")
      notes.redraw()
      api.nvim_set_current_win(notes.state().mine)
      vim.cmd "stopinsert"
    end)

    it("opens over the notes, locked to its buffer, and the same key closes it rather than stacking", function()
      local from = api.nvim_get_current_win()
      notes.read_claude()
      local popup = api.nvim_get_current_win()
      assert.is_not.equals(from, popup)
      assert.is_true(vim.wo[popup].winfixbuf)
      assert.truthy(vim.tbl_contains(api.nvim_buf_get_lines(0, 0, -1, false), "Fixing login"))
      notes.read_claude()
      assert.is_false(api.nvim_win_is_valid(popup))
    end)

    it("closes with q or Ctrl+o, back where you were", function()
      local from = api.nvim_get_current_win()
      for _, key in ipairs { "q", "<C-o>" } do
        notes.read_claude()
        local popup = api.nvim_get_current_win()
        keys(key)
        assert.is_false(api.nvim_win_is_valid(popup), key)
        assert.equals(from, api.nvim_get_current_win(), key)
      end
    end)

    it("says so when Claude hasn't written any", function()
      os.remove(notes.paths(record).claude)
      local messages = H.capture_notify()
      notes.read_claude()
      assert.is_not_nil(H.notified(messages, "No Claude notes"))
    end)
  end)

  describe("Claude's dossier in the pane and the large view", function()
    local buf, record, opened

    local DOSSIER = {
      title = "SD-494 · Console partner sign-in",
      summary = "Partner sign-in",
      now = "Task 1",
      hashtags = { "identity" },
      tasks = { { name = "Task 1", state = "in_progress", detail = "Sonnet implementing" } },
      links = {
        {
          title = "SD-494 · this session's ticket",
          url = "https://x.atlassian.net/browse/SD-494",
          note = "In development",
        },
        { title = "PR #231 cloud/console", url = "https://github.com/cloud/console/pull/231", note = "Opened" },
      },
      decisions = { "One pool per region" },
      details = { "Branch SD-494-signin" },
    }

    local function view_lines()
      return api.nvim_buf_get_lines(0, 0, -1, false)
    end

    local function line_with(lines, text)
      for i, line in ipairs(lines) do
        if line:find(text, 1, true) then
          return i, line
        end
      end
    end

    local function pane_text()
      notes.redraw()
      return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(notes.state().claude), 0, -1, false), "\n")
    end

    -- What the large view highlights as the current link or toggle.
    local function current()
      local ns = api.nvim_get_namespaces().floatterm_claude_view
      local marks = api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
      assert.equals(1, #marks)
      local mark = marks[1]
      return api.nvim_buf_get_lines(0, mark[2], mark[2] + 1, false)[1]:sub(mark[3] + 1, mark[4].end_col)
    end

    local function open_view()
      api.nvim_set_current_win(notes.state().mine)
      vim.cmd "stopinsert"
      notes.read_claude()
      return api.nvim_get_current_win()
    end

    before_each(function()
      buf = H.sleep_tab { label = "api", kind = "claude" }
      ft.update(buf, { status = "working" })
      notes.set(buf, true)
      record = ft.record(buf)
      H.write(notes.paths(record).claude_json, vim.json.encode(DOSSIER))
      opened = {}
      H.stub(vim.ui, "open", function(url)
        table.insert(opened, url)
      end)
    end)

    it("shows the dossier read-only in the pane at its width, folds as one line", function()
      local text = pane_text()
      local width = api.nvim_win_get_width(notes.state().claude)
      for _, line in ipairs(vim.split(text, "\n")) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= width, line)
      end
      assert.truthy(text:find("✳ SD-494 · Console partner sign-in", 1, true))
      assert.truthy(text:find("◌ working · Task 1", 1, true))
      assert.truthy(text:find("PR #231 cloud/console", 1, true))
      assert.is_nil(text:find("https://", 1, true))
      assert.truthy(text:find("▸ Decisions (1) d   ▸ Details (1) t", 1, true))
      assert.is_nil(text:find("One pool per region", 1, true))
      assert.is_false(vim.bo[api.nvim_win_get_buf(notes.state().claude)].modifiable)
    end)

    it("Tab and Shift+Tab move between the links and the toggles, the current one highlighted", function()
      notes.redraw()
      open_view()
      local seen = {}
      for _ = 1, 4 do
        keys "<Tab>"
        table.insert(seen, current())
      end
      assert.same({
        "SD-494 · this session's ticket",
        "PR #231 cloud/console",
        "▸ Decisions (1) d",
        "▸ Details (1) t",
      }, seen)
      keys "<Tab>"
      assert.equals("SD-494 · this session's ticket", current())
      keys "<S-Tab>"
      assert.equals("▸ Details (1) t", current())
    end)

    it("Enter opens a link in the browser, or opens and folds a fold, remembered for the note", function()
      notes.redraw()
      open_view()
      keys "<Tab><Tab><CR>"
      assert.same({ "https://github.com/cloud/console/pull/231" }, opened)
      keys "<Tab><CR>"
      local lines = view_lines()
      assert.is_not_nil(line_with(lines, "▾ Decisions (1) d"))
      assert.is_not_nil(line_with(lines, "  - One pool per region"))
      -- Still on the toggle, to fold it again.
      assert.equals("▾ Decisions (1) d", current())
      local folds = notes.paths(record).claude_folds
      assert.same({ decisions = true }, vim.json.decode(H.read(folds)))
      -- The pane shows it open too.
      H.flush(50)
      assert.truthy(pane_text():find("One pool per region", 1, true))
      keys "<CR>"
      assert.is_nil(line_with(view_lines(), "One pool per region"))
      assert.same(vim.empty_dict(), vim.json.decode(H.read(folds)))
    end)

    it("d and t open and fold Decisions and Details from anywhere", function()
      notes.redraw()
      open_view()
      keys "t"
      assert.is_not_nil(line_with(view_lines(), "  - Branch SD-494-signin"))
      keys "d"
      assert.is_not_nil(line_with(view_lines(), "  - One pool per region"))
      keys "t"
      assert.is_nil(line_with(view_lines(), "Branch SD-494-signin"))
      assert.same({ decisions = true }, vim.json.decode(H.read(notes.paths(record).claude_folds)))
    end)

    it("a click on a link opens it and one on a toggle opens the fold", function()
      notes.redraw()
      local win = open_view()
      -- Headless nvim has no screen to place a real click on, so the click's position
      -- is given as nvim would report it.
      local function click(row, column)
        H.stub(vim.fn, "getmousepos", function()
          return { winid = win, line = row, column = column }
        end)
        keys "<LeftRelease>"
      end
      local function click_on(text)
        local row, line = line_with(view_lines(), text)
        click(row, vim.fn.strdisplaywidth(line:sub(1, line:find(text, 1, true) - 1)) + 2)
      end
      click_on "PR #231"
      assert.same({ "https://github.com/cloud/console/pull/231" }, opened)
      click_on "Details (1)"
      assert.is_not_nil(line_with(view_lines(), "  - Branch SD-494-signin"))
      -- Beside a link, past its title, nothing happens.
      local row, line = line_with(view_lines(), "In development")
      click(row, vim.fn.strdisplaywidth(line))
      assert.equals(1, #opened)
    end)

    it("keeps fold state per note, and opens with it", function()
      notes.set_fold(record.note_id, "details", true)
      notes.redraw()
      open_view()
      assert.is_not_nil(line_with(view_lines(), "▾ Details (1) t"))
      keys "q"
      assert.same({}, notes.folds "20261029-else")
      assert.same({ details = true }, notes.folds(record.note_id))
      -- Deleting the note takes its fold state with it.
      local folds = notes.paths(record).claude_folds
      notes.delete(record.note_id)
      assert.is_false(H.exists(folds))
    end)
  end)

  describe("shared with another nvim", function()
    it("picks up what the other nvim saved when you come back to the notes", function()
      local buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      notes.redraw()
      local win = notes.state().mine
      local mine_buf = api.nvim_win_get_buf(win)
      local path = notes.paths(ft.record(buf)).mine
      -- The other nvim's save, a moment later (mtime has to move).
      vim.uv.sleep(1100)
      H.write(path, "# api\n\nfrom the other nvim\n")
      api.nvim_set_current_win(win)
      H.flush(100)
      -- checktime run from an autocommand waits until nvim next waits for a key; a
      -- key typed here gets it there.
      keys "<Esc>"
      H.flush(50)
      assert.truthy(vim.tbl_contains(api.nvim_buf_get_lines(mine_buf, 0, -1, false), "from the other nvim"))
    end)

    it("doesn't count the empty line you land on as an edit", function()
      local buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      notes.redraw()
      local win = notes.state().mine
      api.nvim_set_current_win(win)
      H.flush(100)
      local mine_buf = api.nvim_win_get_buf(win)
      local count = api.nvim_buf_line_count(mine_buf)
      assert.equals("", api.nvim_buf_get_lines(mine_buf, count - 1, count, false)[1])
      assert.is_false(vim.bo[mine_buf].modified)
    end)

    it("puts the empty typing line back after the other nvim's save is picked up", function()
      local buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      notes.redraw()
      local win = notes.state().mine
      api.nvim_set_current_win(win)
      H.flush(100)
      local mine_buf = api.nvim_win_get_buf(win)
      local path = notes.paths(ft.record(buf)).mine
      H.write(path, "# api\n\nfrom the other nvim\n")
      local later = os.time() + 5
      vim.uv.fs_utime(path, later, later)
      -- Typing, the reload happens. What it left is read from a timer, as x! stays in
      -- insert mode until something ends it.
      local seen
      vim.defer_fn(function()
        seen = {
          lines = api.nvim_buf_get_lines(mine_buf, 0, -1, false),
          cursor = api.nvim_win_get_cursor(win),
          modified = vim.bo[mine_buf].modified,
          mode = api.nvim_get_mode().mode,
        }
        api.nvim_input "<Esc>"
      end, 100)
      keys("A<Cmd>checktime " .. mine_buf .. "<CR>", "x!")
      H.wait(2000, function()
        return seen ~= nil
      end)
      local lines = seen.lines
      assert.equals("from the other nvim", lines[#lines - 1])
      assert.equals("", lines[#lines])
      assert.same({ #lines, 0 }, seen.cursor)
      assert.is_false(seen.modified)
      assert.equals("i", seen.mode)
    end)
  end)

  describe("picker", function()
    it("lists notes newest first with Claude's summary and tags, and filters on them", function()
      local dir = notes.dir()
      vim.fn.mkdir(dir, "p")
      H.write(dir .. "/20261028-aaaa.md", "# login work\n")
      H.write(
        dir .. "/20261028-aaaa.claude.json",
        vim.json.encode { summary = "Fixing login\nmore", hashtags = { "auth", "#deploy" } }
      )
      H.write(dir .. "/20261029-bbbb.md", "# docs\n")
      H.write(dir .. "/20261029-bbbb.claude.md", "# Summary of chat\nWriting docs\n#docs\n")
      vim.uv.fs_utime(dir .. "/20261028-aaaa.md", 1000, 1000)

      local list = notes.list()
      assert.equals("20261029-bbbb", list[1].id)
      assert.equals("Writing docs", list[1].summary)
      assert.same({ "#docs" }, list[1].hashtags)
      assert.equals("Fixing login", list[2].summary)
      assert.same({ "#auth", "#deploy" }, list[2].hashtags)

      -- The picker's entries, matched as telescope would.
      local captured
      H.stub(require "telescope.pickers", "new", function(_, opts)
        captured = opts
        return { find = function() end }
      end)
      notes.pick()
      local sorter = require("telescope.config").values.generic_sorter {}
      local function matches(prompt)
        local found = {}
        for _, note in ipairs(list) do
          local entry = captured.finder.entry_maker(note)
          if sorter:scoring_function(prompt, entry.ordinal, entry) >= 0 then
            table.insert(found, note.id)
          end
        end
        return found
      end
      assert.same({ "20261028-aaaa" }, matches "#deploy")
      assert.same({ "20261029-bbbb" }, matches "writing docs")
      -- Claude's title and what it's doing are searched too.
      H.write(
        dir .. "/20261028-aaaa.claude.json",
        vim.json.encode { title = "SD-494 · Partner sign-in", now = "Seeding users", summary = "s" }
      )
      list = notes.list()
      assert.equals("SD-494 · Partner sign-in", list[2].claude_title)
      assert.same({ "20261028-aaaa" }, matches "SD-494")
      assert.same({ "20261028-aaaa" }, matches "seeding")
    end)
  end)
end)
