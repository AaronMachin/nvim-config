-- lua/floatterm: tabs and their records, events, placements, moving between them, the
-- room kept for the tab bar and the notes pane, and the unwrapped copy.

local H = require "test_helpers"
local api = vim.api

local ft, settings

-- The editor area with lines = 50, columns = 200 and no tab line: 48 rows.
local ROWS, COLS = 48, 200

local function events(pattern)
  local seen = {}
  local id = api.nvim_create_autocmd("User", {
    pattern = pattern,
    callback = function(args)
      table.insert(seen, args.data or {})
    end,
  })
  return seen, function()
    api.nvim_del_autocmd(id)
  end
end

local function title_text(win)
  local title = api.nvim_win_get_config(win).title
  if type(title) == "table" then
    local text = ""
    for _, chunk in ipairs(title) do
      text = text .. chunk[1]
    end
    return text
  end
  return title or ""
end

-- Back to docked at the bottom, large, no full-screen or split. The placement lasts
-- for the whole nvim, so each test starts from here.
local function reset_placement()
  if ft.layout().split then
    ft.toggle_split()
  end
  if ft.layout().full then
    ft.toggle_fullscreen()
  end
  local outer = ft.layout().outer
  if outer.width < 100 and outer.height < 30 then
    ft.switch_mode() -- the box: back to docked
  end
  for _ = 1, 3 do
    outer = ft.layout().outer
    if outer.row == 5 and outer.height == 42 and outer.width == 196 then
      return
    end
    ft.move "bottom"
  end
  error("couldn't get back to docked at the bottom: " .. vim.inspect(ft.layout()))
end

describe("floatterm", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    settings = require "floatterm.settings"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  describe("settings", function()
    it("gives the defaults with no file, and saves a change", function()
      assert.equals("left", settings.get "tabbar")
      settings.set("tabbar_width", 30)
      settings.reload()
      assert.equals(30, settings.get "tabbar_width")
      local saved = vim.json.decode(H.read(settings.path))
      assert.equals(30, saved.tabbar_width)
    end)

    it("ignores unknown keys and values of the wrong type in the file", function()
      H.write(settings.path, vim.json.encode { tabbar = 7, gone = true, hints = false, dock_sizes = { small = 0.3 } })
      settings.reload()
      assert.equals("left", settings.get "tabbar")
      assert.is_false(settings.get "hints")
      assert.is_nil(settings.all().gone)
      -- A table setting keeps the defaults it doesn't name.
      assert.same({ large = 0.9, small = 0.3 }, settings.get "dock_sizes")
    end)

    it("refuses a setting it doesn't know", function()
      assert.has_error(function()
        settings.set("nope", 1)
      end)
    end)

    it("fires FloatTermSettingsChanged with the key", function()
      local seen, stop = events "FloatTermSettingsChanged"
      settings.set("hints", false)
      stop()
      assert.same({ { key = "hints" } }, seen)
    end)
  end)

  describe("tabs and records", function()
    it("gives each tab a record and its id as $FLOATTERM_TAB_ID", function()
      local _, buf = ft.new_tab({ "sh", "-c", "echo tab=$FLOATTERM_TAB_ID; sleep 300" }, { label = "one" })
      local record = ft.record(buf)
      assert.equals("shell", record.kind)
      assert.equals("one", record.label)
      assert.equals(vim.uv.cwd(), record.cwd)
      assert.equals("one", ft.name(record))
      H.wait(3000, function()
        return api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "tab=" .. record.id
      end, "tab id not in the job's environment")
    end)

    it("names an unlabelled tab after its folder", function()
      local dir = H.tmpdir "project"
      local buf = H.sleep_tab { cwd = dir }
      assert.equals(vim.fs.basename(dir), ft.name(ft.record(buf)))
    end)

    it("opens a new tab next to the one showing, and a hidden one at the end", function()
      local a = H.sleep_tab { label = "a" }
      local b = H.sleep_tab { label = "b" }
      ft.focus_buf(a)
      local c = H.sleep_tab { label = "c" }
      local labels = vim.tbl_map(function(r)
        return r.label
      end, ft.tabs())
      assert.same({ "a", "c", "b" }, labels)
      assert.equals(c, ft.current_buf())

      local _, d = ft.new_tab({ "sleep", "300" }, { label = "d", show = false })
      assert.equals("d", ft.tabs()[4].label)
      assert.equals(c, ft.current_buf())
      assert.is_true(ft.is_showing(c))
      assert.is_false(ft.is_showing(d))
      assert.is_not_nil(b)
    end)

    it("announces changes with the fields that changed, and clears vim.NIL", function()
      local buf = H.sleep_tab()
      local seen, stop = events "FloatTermTabChanged"
      ft.update(buf, { title = "hello", label = "x" })
      ft.update(buf, { title = "hello" }) -- unchanged: no event
      ft.update(buf, { label = vim.NIL })
      stop()
      assert.equals(2, #seen)
      table.sort(seen[1].fields)
      assert.same({ "label", "title" }, seen[1].fields)
      assert.equals(buf, seen[1].buf)
      assert.same({ "label" }, seen[2].fields)
      assert.is_nil(ft.record(buf).label)
    end)

    it("stamps status_since when the status changes", function()
      local buf = H.sleep_tab()
      ft.update(buf, { status = "working" })
      assert.is_number(ft.record(buf).status_since)
      ft.update(buf, { status = "done", status_since = 5 })
      assert.equals(5, ft.record(buf).status_since)
    end)

    it("fires FloatTermTabsChanged as tabs come and go, and drops a tab when its job ends", function()
      local seen, stop = events "FloatTermTabsChanged"
      local a = H.sleep_tab { label = "a" }
      local b = H.sleep_tab { label = "b" }
      local before = #seen
      assert.is_true(before >= 2)
      ft.close_tab(b)
      H.wait(3000, function()
        return #ft.tabs() == 1
      end)
      stop()
      assert.is_true(#seen > before)
      assert.equals(a, ft.current_buf())
      assert.is_true(ft.is_showing(a))
      H.wait(1000, function()
        return not api.nvim_buf_is_valid(b)
      end, "closed tab's buffer kept")
    end)

    it("hides the float when the last tab closes", function()
      local a = H.sleep_tab()
      ft.close_tab(a)
      H.wait(3000, function()
        return #ft.tabs() == 0
      end)
      assert.is_false(ft.is_open())
    end)
  end)

  describe("switching and moving tabs", function()
    it("goes to the next and previous tab, wrapping round", function()
      local a = H.sleep_tab { label = "a" }
      local b = H.sleep_tab { label = "b" }
      local c = H.sleep_tab { label = "c" }
      ft.next_tab()
      assert.equals(a, ft.current_buf())
      ft.previous_tab()
      assert.equals(c, ft.current_buf())
      ft.previous_tab()
      assert.equals(b, ft.current_buf())
    end)

    it("moves a tab along, stopping at the ends, and keeps the showing tab showing", function()
      local a = H.sleep_tab { label = "a" }
      H.sleep_tab { label = "b" }
      local c = H.sleep_tab { label = "c" }
      ft.move_tab(a, 1)
      ft.move_tab(a, 5)
      local labels = vim.tbl_map(function(r)
        return r.label
      end, ft.tabs())
      assert.same({ "b", "c", "a" }, labels)
      assert.equals(c, ft.current_buf())
      ft.move_tab(a, 1) -- already last
      assert.equals("a", ft.tabs()[3].label)
    end)

    it("lists every tab in the border title when the tab bar is off", function()
      settings.set("tabbar", "off")
      H.sleep_tab { label = "a" }
      H.sleep_tab()
      local title = title_text(ft.window())
      assert.truthy(title:find("1 a", 1, true))
      assert.truthy(title:find("[2]", 1, true))
    end)

    it("opens on the tab that has waited longest for you", function()
      local a = H.sleep_tab { label = "a" }
      local b = H.sleep_tab { label = "b" }
      local c = H.sleep_tab { label = "c" }
      ft.update(c, { status = "needs_you", status_since = 200 })
      ft.update(b, { status = "needs_you", status_since = 100 })
      ft.focus_buf(a)
      ft.toggle() -- hide
      assert.is_false(ft.is_open())
      ft.toggle()
      assert.equals(b, ft.current_buf())
    end)

    it("force-closes a shell tab at once and asks first for a Claude tab", function()
      local shell = H.sleep_tab { label = "shell" }
      local claude = H.sleep_tab { label = "claude", kind = "claude" }
      local prompts = H.answer_select("Keep it")
      ft.close_current()
      H.flush(100)
      assert.equals(1, #prompts)
      assert.truthy(prompts[1]:find "claude")
      assert.equals(2, #ft.tabs())

      ft.focus_buf(shell)
      ft.close_current()
      H.wait(3000, function()
        return #ft.tabs() == 1
      end)
      assert.equals(claude, ft.tabs()[1].buf)
    end)
  end)

  describe("placements", function()
    before_each(function()
      H.sleep_tab()
      reset_placement()
    end)

    it("docks at the bottom, large, with the tab bar down the left", function()
      local layout = ft.layout()
      assert.same({ row = 5, col = 2, height = 42, width = 196 }, layout.outer)
      assert.same({ row = 5, col = 2, height = 42, width = 28 }, layout.tabbar)
      assert.same({ row = 5, col = 30, height = 42, width = 168 }, layout.terminal)
      local config = api.nvim_win_get_config(ft.window())
      assert.equals(40, config.height)
      assert.equals(166, config.width)
    end)

    it("flips between large and small on its own edge, and docks large on another", function()
      ft.move "bottom"
      assert.equals(8, ft.layout().outer.height) -- 20% of 48 rows, less the gap
      ft.move "bottom"
      assert.equals(42, ft.layout().outer.height)
      ft.move "left"
      local outer = ft.layout().outer
      assert.equals(2, outer.col)
      assert.equals(math.floor(COLS * 0.9) - 2, outer.width)
      assert.equals(ROWS - 2, outer.height)
    end)

    it("moves the box one square at a time and stops at the edge of the grid", function()
      ft.switch_mode()
      local outer = ft.layout().outer
      assert.equals(15, outer.height) -- a third of 48 rows, less the gap
      assert.equals(64, outer.width) -- a third of 200 columns, less the gaps
      for _ = 1, 3 do
        ft.move "top"
        ft.move "left"
      end
      assert.same({ row = 1, col = 1, height = 15, width = 64 }, ft.layout().outer)
      ft.move "right"
      assert.equals(67, ft.layout().outer.col)
      ft.move "right"
      ft.move "right"
      assert.equals(133, ft.layout().outer.col)
      -- Back to docked where it was.
      ft.switch_mode()
      assert.equals(42, ft.layout().outer.height)
    end)

    it("goes full-screen and back to where it was", function()
      ft.move "bottom" -- small
      ft.toggle_fullscreen()
      assert.same({ row = 0, col = 0, height = ROWS, width = COLS }, ft.layout().outer)
      assert.is_true(ft.layout().full)
      ft.toggle_fullscreen()
      assert.equals(8, ft.layout().outer.height)
    end)

    it("leaves full-screen docked large at the edge a move key points to", function()
      ft.toggle_fullscreen()
      ft.move "top"
      local outer = ft.layout().outer
      assert.is_false(ft.layout().full)
      assert.equals(1, outer.row)
      assert.equals(42, outer.height)
    end)

    it("becomes a real split with its tab bar beside it, and back to the float", function()
      ft.toggle_split()
      local layout = ft.layout()
      assert.is_true(layout.split)
      assert.equals("", api.nvim_win_get_config(ft.window()).relative)
      assert.is_not_nil(layout.tabbar)
      -- Small, at the bottom: 20% of the editor's rows.
      assert.equals(math.floor(ROWS * 0.2), api.nvim_win_get_height(ft.window()))

      -- The edge it's on flips its size; another edge moves it there.
      ft.move "bottom"
      assert.equals("", api.nvim_win_get_config(ft.window()).relative)
      ft.move "right"
      assert.is_true(ft.layout().split)
      assert.equals("", api.nvim_win_get_config(ft.window()).relative)

      ft.toggle_split()
      assert.is_false(ft.layout().split)
      assert.equals("editor", api.nvim_win_get_config(ft.window()).relative)
      -- No split windows left behind.
      local normal = vim.tbl_filter(function(w)
        return api.nvim_win_get_config(w).relative == ""
      end, api.nvim_tabpage_list_wins(0))
      assert.equals(1, #normal)
    end)

    it("goes from the split to full-screen", function()
      ft.toggle_split()
      ft.toggle_fullscreen()
      assert.is_true(ft.layout().full)
      assert.is_false(ft.layout().split)
    end)

    it("refuses a move that would leave the terminal too small", function()
      vim.o.lines = 14
      H.flush(30)
      local before = ft.layout().outer
      ft.move "bottom" -- small would be 2 rows
      assert.same(before, ft.layout().outer)
      vim.o.lines = 50
      H.flush(30)
    end)

    it("remembers the placement for the folder", function()
      ft.move "left"
      local folder = vim.uv.fs_realpath(vim.uv.cwd())
      local file = ft.placement_dir .. "/" .. folder:gsub("/", "%%") .. ".json"
      local saved = vim.json.decode(H.read(file))
      assert.equals("left", saved.edge)
      assert.equals("dock", saved.mode)
    end)

    it("opens where it was last in a fresh nvim in the same folder", function()
      local dir = H.tmpdir "remember"
      local project = H.tmpdir "project"
      local code = [[
        local ft = require "floatterm"
        ft.new_tab({ "sleep", "30" })
        ft.move "top"
        ft.move "top"
      ]]
      H.child(project, code, { floatterm_placement_dir = dir })
      local out = H.child(project, [[
        local ft = require "floatterm"
        ft.new_tab({ "sleep", "30" })
        io.stdout:write(vim.json.encode(ft.layout().outer))
      ]], { floatterm_placement_dir = dir })
      local outer = vim.json.decode(out)
      assert.equals(1, outer.row) -- docked at the top
      assert.equals(math.floor(ROWS * 0.2) - 1, outer.height) -- and small
    end)
  end)

  describe("room for the tab bar", function()
    before_each(function()
      H.sleep_tab()
      reset_placement()
    end)

    it("keeps one row along the top", function()
      settings.set("tabbar", "top")
      local layout = ft.layout()
      assert.same({ row = 5, col = 2, height = 1, width = 196 }, layout.tabbar)
      assert.same({ row = 6, col = 2, height = 41, width = 196 }, layout.terminal)
    end)

    it("keeps none when off", function()
      settings.set("tabbar", "off")
      assert.is_nil(ft.layout().tabbar)
      assert.same(ft.layout().outer, ft.layout().terminal)
    end)

    it("drops the bar rather than leave the terminal too narrow", function()
      settings.set("tabbar_width", 60)
      ft.move "left"
      ft.move "left" -- small: 20% of 200 columns
      local layout = ft.layout()
      assert.is_nil(layout.tabbar)
    end)
  end)

  describe("room for the notes pane", function()
    local buf
    before_each(function()
      buf = H.sleep_tab()
      reset_placement()
    end)

    it("takes the notes share of the terminal's room on the notes side", function()
      ft.update(buf, { notes_on = true })
      local layout = ft.layout()
      assert.same({ row = 5, col = 140, height = 42, width = 58 }, layout.notes)
      assert.same({ row = 5, col = 30, height = 42, width = 110 }, layout.terminal)
      assert.is_false(layout.notes_hidden)

      settings.set("notes_side", "bottom")
      layout = ft.layout()
      assert.equals(14, layout.notes.height) -- 35% of 42
      assert.equals(5 + 42 - 14, layout.notes.row)
      assert.equals(28, layout.terminal.height)
    end)

    it("hides the notes in the box placement and says so in the title", function()
      ft.update(buf, { notes_on = true })
      ft.switch_mode()
      local layout = ft.layout()
      assert.is_nil(layout.notes)
      assert.is_true(layout.notes_hidden)
      assert.truthy(title_text(ft.window()):find("notes hidden", 1, true))
    end)

    it("holds a window for the notes beside the split", function()
      ft.update(buf, { notes_on = true })
      ft.toggle_split()
      local layout = ft.layout()
      assert.is_not_nil(layout.notes_window)
      assert.equals("", api.nvim_win_get_config(layout.notes_window).relative)
      ft.update(buf, { notes_on = false })
      assert.is_nil(ft.layout().notes_window)
    end)
  end)

  describe("copying from a terminal tab", function()
    it("joins lines the terminal only wrapped and keeps real breaks", function()
      local long = string.rep("abcdefghij", 30)
      local _, buf = ft.new_tab { "sh", "-c", "printf '%s\\n' " .. long .. "; echo '  indented'; echo next; sleep 300" }
      H.wait(3000, function()
        return vim.tbl_contains(api.nvim_buf_get_lines(buf, 0, -1, false), "next")
      end)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      -- The terminal split the long line.
      assert.is_true(#lines[1] < #long)
      local next_line = vim.fn.index(lines, "next") + 1
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "x", false)
      vim.cmd("normal! " .. next_line .. "GVgg")
      assert.equals(long .. "\n  indented\nnext", ft.unwrapped_selection())
    end)
  end)
end)
