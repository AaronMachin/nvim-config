-- lua/floatterm/notes: where notes live, switching them on and off, the captures,
-- tidying away empty notes, Claude's pop-up, sharing with another nvim, and the
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

  describe("empty notes", function()
    local function close(buf)
      ft.close_tab(buf)
      H.wait(3000, function()
        return ft.record(buf) == nil
      end)
      H.flush(50)
    end

    it("deletes a note with nothing but its heading when its tab closes", function()
      local buf = H.sleep_tab { label = "api" }
      notes.set(buf, true)
      local mine = notes.paths(ft.record(buf)).mine
      close(buf)
      assert.is_false(H.exists(mine))
    end)

    it("keeps one with something written, a changed heading, or Claude's part", function()
      local kept = {}
      for _, case in ipairs { "written", "heading", "claude" } do
        local buf = H.sleep_tab { label = "api" }
        notes.set(buf, true)
        local p = notes.paths(ft.record(buf))
        if case == "written" then
          H.write(p.mine, "# api\n\nremember this\n")
        elseif case == "heading" then
          H.write(p.mine, "# login work\n")
        else
          H.write(p.claude, "summary\n")
        end
        vim.cmd "checktime"
        kept[case] = p.mine
        close(buf)
      end
      for case, path in pairs(kept) do
        assert.is_true(H.exists(path), case)
      end
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
    end)
  end)
end)
