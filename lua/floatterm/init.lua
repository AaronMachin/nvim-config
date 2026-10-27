-- Floating terminal with tabs.
--
-- One float window shows one of several terminal buffers at a time. Hiding the float
-- leaves every tab running; it reopens on the tab last shown, or on a tab whose Claude
-- needs you. A tab closes when its job exits.
--
-- The float is docked to an edge of the editor, floating in one square of a 3x3 grid,
-- or full-screen. Or the terminal leaves the float and becomes a real split beside
-- the code (`split` placement), moved and sized by the same keys. A line of key hints sits in the gap above or below it, or in its
-- bottom border when there's no gap. With the tab bar on (settings), part of the float
-- is kept for it and lua/floatterm/tabbar draws it.
--
-- Each tab has a record (see M.tabs) that other modules read and change through
-- M.update. Changes fire User events so anything showing them can redraw:
--   FloatTermTabsChanged   a tab was added or removed, or another tab is showing
--   FloatTermTabChanged    a record changed; data = { buf, id, fields = { names } }
--   FloatTermLayoutChanged the float opened, closed, moved or resized; data = { open }

local M = {}

local api = vim.api
local settings = require "floatterm.settings"

-- Records, in tab order:
--   id            unique for this nvim, also given to the job as $FLOATTERM_TAB_ID
--   buf, job
--   kind          "shell" or "claude"
--   cwd           the folder the tab started in
--   label         a name the user gave it, or nil
--   command       what's running in it (a shell tab's foreground command), or nil
--   title         the title the job set (Claude's task summary), or nil
--   status        a Claude tab's "needs_you", "working" or "done", or nil
--   status_since  os.time() when status last changed
--   session_id    a Claude tab's conversation, or nil
-- Other modules may keep their own fields on a record too.
local tabs = {}
local current = 0
local next_id = 1
local win = nil
-- In split placement, an empty window kept beside the terminal for the tab bar to
-- draw over, so the bar takes space from the split rather than covering it.
local bar_win = nil
local hint_win = nil
local hint_buf = nil
local hints_shown = settings.get "hints"
-- Keys added by other modules for every tab buffer: { lhs, fn, desc }.
local extra_keys = {}

local function start_placement()
  local start = settings.get "start_position"
  local placement = {
    mode = "dock",
    edge = "bottom",
    size = "large",
    cell = { row = 1, col = 1 },
    full = false,
    split = { on = false, edge = "bottom", size = "small" },
  }
  if start == "split" then
    placement.split.on = true
  elseif start == "box" then
    placement.mode = "float"
  elseif start == "top" or start == "left" or start == "right" then
    placement.edge = start
  end
  return placement
end

-- Each project (the folder nvim was started in) remembers where the terminal last was,
-- full-screen and split included, in stdpath("data")/floatterm-placement/. The
-- start_position setting is only for a project with nothing remembered yet.
-- A field rather than a local so tests can point it somewhere else.
-- The vim.g overrides are for tests, set with --cmd before the config loads.
M.placement_dir = vim.g.floatterm_placement_dir or (vim.fn.stdpath "data" .. "/floatterm-placement")

local function placement_file()
  -- Not for nvim opened on files (git's editor, say) or headless runs.
  -- The --headless flag rather than nvim_list_uis(): no UI has attached yet while the
  -- config loads, even in a normal start.
  if vim.fn.argc() > 0 or (vim.tbl_contains(vim.v.argv, "--headless") and not vim.g.floatterm_placement_dir) then
    return nil
  end
  local folder = vim.uv.fs_realpath(vim.uv.cwd())
  return folder and (M.placement_dir .. "/" .. folder:gsub("/", "%%") .. ".json") or nil
end

-- The remembered placement over the defaults, so a field added later still has a value.
local function remembered_placement()
  local placement = start_placement()
  local path = placement_file()
  local file = path and io.open(path, "r")
  if not file then
    return placement
  end
  local ok, saved = pcall(vim.json.decode, file:read "*a")
  file:close()
  if ok and type(saved) == "table" then
    placement = vim.tbl_deep_extend("force", placement, saved)
  end
  return placement
end

local function remember_placement(p)
  local path = placement_file()
  if not path then
    return
  end
  vim.fn.mkdir(M.placement_dir, "p")
  local file = io.open(path, "w")
  if file then
    file:write(vim.json.encode(p))
    file:close()
  end
end

-- Where the float is. Docked, `edge` and `size` apply; floating, `cell` does (0-2 each
-- way, starting in the centre). Both are kept so switching back returns to the last
-- spot, and `full` sits on top of either. With split.on, the terminal is a real split
-- at split.edge taking split.size of the editor, and the float's spot is kept for
-- when it goes back.
local placement = remembered_placement()

-- Everything else is in the options panel (lua/floatterm/menu).
local HINTS = "Ctrl+x then <leader>o for options"
local SHORT_HINTS = HINTS

-- The full hints if they fit in `width` columns with a space either side, else the short ones.
local function hints_for(width)
  return vim.fn.strdisplaywidth(HINTS) + 2 <= width and HINTS or SHORT_HINTS
end

-- A cell is about twice as tall as it is wide, so 2 columns looks like 1 row.
local SIDE_GAP = 2
local EDGE_GAP = 1
-- A move that would leave the terminal smaller than this does nothing.
local MIN_ROWS = 5
local MIN_COLS = 20

local function fire(pattern, data)
  api.nvim_exec_autocmds("User", { pattern = pattern, data = data or {} })
end

-- The float's outer box (border included) for a placement, in an editor area of
-- `rows` x `cols`.
local function geometry(p, rows, cols)
  if p.full then
    return { row = 0, col = 0, height = rows, width = cols }
  end

  if p.mode == "float" then
    local cell_height = math.floor(rows / 3)
    local cell_width = math.floor(cols / 3)
    return {
      row = p.cell.row * cell_height + EDGE_GAP,
      col = p.cell.col * cell_width + SIDE_GAP / 2,
      height = cell_height - EDGE_GAP,
      width = cell_width - SIDE_GAP,
    }
  end

  local sizes = settings.get "dock_sizes"
  if p.edge == "top" or p.edge == "bottom" then
    local share = math.floor(rows * sizes[p.size])
    return {
      row = p.edge == "top" and EDGE_GAP or rows - share,
      col = SIDE_GAP,
      height = share - EDGE_GAP,
      width = cols - 2 * SIDE_GAP,
    }
  end

  local share = math.floor(cols * sizes[p.size])
  return {
    row = EDGE_GAP,
    col = p.edge == "left" and SIDE_GAP or cols - share,
    height = rows - 2 * EDGE_GAP,
    width = share - SIDE_GAP,
  }
end

-- Splits an outer box between the tab bar and the terminal. The bar is dropped when
-- keeping it would leave the terminal too small.
local function split(outer)
  local bar = settings.get "tabbar"
  if bar == "left" then
    local width = math.min(settings.get "tabbar_width", math.floor(outer.width / 2))
    if outer.width - width - 2 >= MIN_COLS then
      return {
        tabbar = { row = outer.row, col = outer.col, height = outer.height, width = width },
        terminal = { row = outer.row, col = outer.col + width, height = outer.height, width = outer.width - width },
      }
    end
  elseif bar == "top" then
    if outer.height - 1 - 2 >= MIN_ROWS then
      return {
        tabbar = { row = outer.row, col = outer.col, height = 1, width = outer.width },
        terminal = { row = outer.row + 1, col = outer.col, height = outer.height - 1, width = outer.width },
      }
    end
  end
  return { terminal = outer }
end

-- The editor rows a float can use, and the first of them: everything between the tab
-- line (NvChad's buffer line, when it shows) and the statusline.
local function editor_area()
  local tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)
  local top = tabline and 1 or 0
  return vim.o.lines - vim.o.cmdheight - 1 - top, vim.o.columns, top
end

local function shifted(box, top)
  return box and { row = box.row + top, col = box.col, height = box.height, width = box.width } or nil
end

-- Boxes for a placement (current by default), border included: outer is the whole
-- float, terminal the terminal window, tabbar the tab bar's share (nil when off).
-- Rows are editor rows, below the tab line.
local function boxes(p)
  local rows, cols, top = editor_area()
  local outer = geometry(p or placement, rows, cols)
  local parts = split(outer)
  return { outer = shifted(outer, top), terminal = shifted(parts.terminal, top), tabbar = shifted(parts.tabbar, top) }
end

-- Where the hints line goes: the row above the float, the row below it, or (with
-- neither free) its bottom border. Never on the tab line.
local function hints_row(outer)
  local rows, _, top = editor_area()
  if outer.row >= top + 1 then
    return outer.row - 1
  end
  if outer.row + outer.height < top + rows then
    return outer.row + outer.height
  end
  return nil
end

local function win_is_open()
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function is_split_window(w)
  return w ~= nil and api.nvim_win_is_valid(w) and api.nvim_win_get_config(w).relative == ""
end

local SPLIT_SIDES = { bottom = "below", top = "above", left = "left", right = "right" }

-- The terminal split's size for a placement: rows for top/bottom, columns for
-- left/right, as a share of the editor.
local function split_size(p)
  local rows, cols = editor_area()
  local horizontal = p.split.edge == "top" or p.split.edge == "bottom"
  local total = horizontal and rows or cols
  -- The code beside it keeps the terminal's own minimum, so 90% of a narrow editor
  -- doesn't leave it a column wide.
  local keep = horizontal and MIN_ROWS + 1 or MIN_COLS + 1
  return math.min(math.floor(total * settings.get("dock_sizes")[p.split.size]), total - keep), horizontal
end

-- The split's windows as boxes (the same shape as the float's, for the tab bar):
-- terminal, plus tabbar when the bar has its window.
local function split_boxes()
  local function box_of(w)
    local pos = api.nvim_win_get_position(w)
    return { row = pos[1], col = pos[2], height = api.nvim_win_get_height(w), width = api.nvim_win_get_width(w) }
  end
  local terminal = box_of(win)
  local tabbar = bar_win and api.nvim_win_is_valid(bar_win) and box_of(bar_win) or nil
  return { outer = terminal, terminal = terminal, tabbar = tabbar }
end

local function close_split_windows()
  if bar_win and api.nvim_win_is_valid(bar_win) then
    pcall(api.nvim_win_close, bar_win, true)
  end
  bar_win = nil
  if is_split_window(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

local function index_of(buf)
  for i, record in ipairs(tabs) do
    if record.buf == buf then
      return i
    end
  end
  return nil
end

-- A tab's name: the one it was given, else its folder's.
function M.name(record)
  return record.label or vim.fn.fnamemodify(record.cwd, ":t")
end

-- With the tab bar showing, the border only names the current tab; without it, the
-- border lists every tab.
local function title(layout)
  if layout.tabbar then
    return " " .. M.name(tabs[current]) .. " "
  end

  local names = {}
  for i, record in ipairs(tabs) do
    local name = record.label and (i .. " " .. record.label) or tostring(i)
    names[i] = i == current and ("[" .. name .. "]") or name
  end
  return " " .. table.concat(names, " │ ") .. " "
end

local function float_config()
  local layout = boxes()
  local box = layout.terminal
  local in_footer = hints_shown and hints_row(layout.outer) == nil

  -- The border adds a row above and below, and a column either side.
  return {
    relative = "editor",
    border = "rounded",
    row = box.row,
    col = box.col,
    -- At least 1: shrinking the editor can leave a placement too small to draw, and
    -- nvim refuses a zero size.
    height = math.max(1, box.height - 2),
    width = math.max(1, box.width - 2),
    title = title(layout),
    title_pos = "center",
    footer = in_footer and (" " .. hints_for(box.width - 2) .. " ") or "",
    footer_pos = "center",
  }
end

local function close_hints()
  if hint_win and api.nvim_win_is_valid(hint_win) then
    api.nvim_win_close(hint_win, true)
  end
  hint_win = nil
end

-- Shows the hints line in the gap above or below the float, centred on it. It may be
-- wider than the float (a floating box is a third of the editor), but stays on screen.
local function show_hints()
  close_hints()
  if placement.split.on then
    return
  end

  local _, cols = editor_area()
  local outer = boxes().outer
  local row = hints_row(outer)
  if not hints_shown or row == nil then
    return
  end

  if not (hint_buf and api.nvim_buf_is_valid(hint_buf)) then
    hint_buf = api.nvim_create_buf(false, true)
  end
  local hints = hints_for(cols)
  api.nvim_buf_set_lines(hint_buf, 0, -1, false, { hints })

  local width = math.min(vim.fn.strdisplaywidth(hints), cols)
  local centred = outer.col + math.floor((outer.width - width) / 2)
  hint_win = api.nvim_open_win(hint_buf, false, {
    relative = "editor",
    row = row,
    col = math.max(0, math.min(centred, cols - width)),
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    noautocmd = true,
  })
  vim.wo[hint_win].winhighlight = "Normal:Comment"
end

-- Re-applies the layout to an open float, after a move, a resize or a settings change.
local function relayout()
  if placement.split.on then
    if is_split_window(win) then
      local size, horizontal = split_size(placement)
      if horizontal then
        api.nvim_win_set_height(win, math.max(MIN_ROWS, size))
      else
        api.nvim_win_set_width(win, math.max(MIN_COLS, size))
      end
    end
  elseif win_is_open() then
    api.nvim_win_set_config(win, float_config())
    show_hints()
  end
  fire("FloatTermLayoutChanged", { open = win_is_open() })
end

local function apply_winopts(w)
  for option, value in pairs(require("nvconfig").term.winopts) do
    vim.wo[w][option] = value
  end
end

-- Opens the terminal as a real split at split.edge, from a normal window, with an
-- empty window beside it for the tab bar when the bar is on and fits.
local function open_split(buf)
  local size, horizontal = split_size(placement)
  local edge = { split = SPLIT_SIDES[placement.split.edge], win = -1 }
  if horizontal then
    edge.height = size
  else
    edge.width = size
  end

  local bar = settings.get "tabbar"
  local fits = split({
    row = 0,
    col = 0,
    height = (horizontal and size or select(1, editor_area())) + 2,
    width = (horizontal and vim.o.columns or size) + 2,
  })

  if not fits.tabbar then
    win = api.nvim_open_win(buf, true, edge)
  else
    -- The bar's window opens first as the whole split, and the terminal inside it, so
    -- the two share the split's room and the code beside it keeps its own.
    local scratch = api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    bar_win = api.nvim_open_win(scratch, false, edge)
    win = api.nvim_open_win(buf, true, { split = bar == "left" and "right" or "below", win = bar_win })
    if bar == "left" then
      api.nvim_win_set_width(bar_win, fits.tabbar.width)
    else
      api.nvim_win_set_height(bar_win, 1)
    end
    for option, value in pairs {
      winfixwidth = true,
      winfixheight = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      cursorline = false,
      statuscolumn = "",
      winbar = "",
    } do
      vim.wo[bar_win][option] = value
    end
  end

  apply_winopts(win)
  vim.wo[win].winfixheight = horizontal
  vim.wo[win].winfixwidth = not horizontal
end

-- Puts the current tab's buffer in the float, opening the float if it's hidden.
local function show_current()
  local buf = tabs[current].buf

  if placement.split.on then
    close_hints()
    if win_is_open() and not is_split_window(win) then
      -- The float, from before switching to the split.
      api.nvim_win_close(win, true)
      win = nil
    end
    if not is_split_window(win) then
      open_split(buf)
    else
      api.nvim_win_set_buf(win, buf)
    end
    -- Without the bar there's no border title, so the tabs go in the winbar.
    vim.wo[win].winbar = bar_win and "" or title({}):gsub("%%", "%%%%")
    api.nvim_set_current_win(win)
    vim.cmd "startinsert"
    fire("FloatTermLayoutChanged", { open = true })
    fire "FloatTermTabsChanged"
    return
  end

  if is_split_window(win) then
    close_split_windows()
    win = nil
  end

  if win_is_open() then
    api.nvim_win_set_buf(win, buf)
    api.nvim_win_set_config(win, float_config())
  else
    win = api.nvim_open_win(buf, true, float_config())
    for option, value in pairs(require("nvconfig").term.winopts) do
      vim.wo[win][option] = value
    end
  end

  show_hints()
  api.nvim_set_current_win(win)
  vim.cmd "startinsert"
  fire("FloatTermLayoutChanged", { open = true })
  fire "FloatTermTabsChanged"
end

local function hide()
  close_hints()
  if is_split_window(win) then
    close_split_windows()
  elseif win_is_open() then
    api.nvim_win_close(win, true)
  end
  win = nil
  fire("FloatTermLayoutChanged", { open = false })
end

local function map_tab_keys(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set({ "n", "t" }, lhs, rhs, { buffer = buf, desc = desc })
  end

  map("<C-t>", M.new_tab, "terminal new tab")
  -- In a Claude tab, Ctrl+u/d scroll the conversation while you type: Claude draws it
  -- on the alternate screen, which nvim can't scroll, so they send Claude its own
  -- PageUp/PageDown. Anywhere else they go to the shell as usual.
  for lhs, keys in pairs { ["<C-u>"] = { "\27[5~", "\21" }, ["<C-d>"] = { "\27[6~", "\4" } } do
    vim.keymap.set("t", lhs, function()
      local record = M.record(buf)
      if record and record.job then
        api.nvim_chan_send(record.job, record.kind == "claude" and keys[1] or keys[2])
      end
    end, { buffer = buf, desc = "terminal scroll Claude, or the key as usual" })
  end
  -- Ctrl+Shift+Space, as macOS keeps Ctrl+Space for switching input sources. Plain
  -- Ctrl+Space (<C-Space>, or NUL as <C-@> in some terminal apps) works too where it
  -- gets through.
  for _, lhs in ipairs { "<C-S-Space>", "<C-Space>", "<C-@>" } do
    map(lhs, function() require("floatterm.menu").open() end, "terminal options panel")
  end
  map("<C-S-\\>", M.next_tab, "terminal next tab")
  map("<C-S-n>", M.next_tab, "terminal next tab")
  map("<C-S-p>", M.previous_tab, "terminal previous tab")
  -- h/j/k/l as well as the arrows: some terminal apps keep Ctrl+Shift+left/right.
  for _, keys in ipairs {
    { "<C-S-Left>", "<C-S-h>", "left" },
    { "<C-S-Right>", "<C-S-l>", "right" },
    { "<C-S-Up>", "<C-S-k>", "top" },
    { "<C-S-Down>", "<C-S-j>", "bottom" },
  } do
    for i = 1, 2 do
      map(keys[i], function() M.move(keys[3]) end, "terminal move " .. keys[3] .. " (or resize at that edge)")
    end
  end
  map("<C-S-d>", M.toggle_split, "terminal switch between floating and a split")
  -- Ctrl+Option+arrows reorder tabs, where the terminal app sends Option as Alt.
  for lhs, delta in pairs { ["<C-M-Left>"] = -1, ["<C-M-Up>"] = -1, ["<C-M-Right>"] = 1, ["<C-M-Down>"] = 1 } do
    map(lhs, function() M.move_tab(buf, delta) end, "terminal move tab " .. (delta < 0 and "earlier" or "later"))
  end
  -- Not Ctrl+Shift+m: Neovim reads that as Shift+Enter, which Claude needs for new lines.
  map("<C-S-g>", M.switch_mode, "terminal switch between docked and floating box")
  map("<C-S-f>", M.toggle_fullscreen, "terminal full-screen on or off")
  for _, key in ipairs(extra_keys) do
    map(key[1], key[2], key[3])
  end
end

-- Adds a key to every tab, now and later, in normal and terminal mode.
function M.add_tab_key(lhs, fn, desc)
  table.insert(extra_keys, { lhs, fn, desc })
  for _, record in ipairs(tabs) do
    vim.keymap.set({ "n", "t" }, lhs, fn, { buffer = record.buf, desc = desc })
  end
end

-- Opens a tab running `argv` (a shell by default). The tab closes when it exits.
-- opts: cwd and env for the job; label; kind ("shell" unless given); session_id;
-- show = false to open it without showing the float (or changing the tab showing).
-- Returns the tab's terminal job id and its buffer.
function M.new_tab(argv, opts)
  opts = opts or {}
  local show = opts.show ~= false
  local buf = api.nvim_create_buf(false, true)
  local record = {
    id = next_id,
    buf = buf,
    kind = opts.kind or "shell",
    cwd = opts.cwd or vim.uv.cwd(),
    label = opts.label,
    session_id = opts.session_id,
  }
  next_id = next_id + 1
  table.insert(tabs, record)
  if show or current == 0 then
    current = #tabs
  end

  if show then
    show_current()
  end
  local env = vim.tbl_extend("force", opts.env or {}, {
    FLOATTERM_TAB_ID = tostring(record.id),
  })
  api.nvim_buf_call(buf, function()
    -- A bare { shell } is deleted by Neovim's own TermClose handler before ours
    -- runs, taking the float with it. -i is what the shell would be anyway.
    record.job = vim.fn.termopen(type(argv) == "table" and argv or { vim.o.shell, "-i" }, {
      cwd = record.cwd,
      env = env,
    })
  end)
  map_tab_keys(buf)
  if show then
    -- termopen renames the buffer, so the title is set again after it.
    show_current()
  else
    fire "FloatTermTabsChanged"
  end
  return record.job, buf
end

-- Opens a shell tab and types `command` into it, so the shell stays open afterwards
-- with the output to read. opts as for new_tab.
function M.run_in_tab(command, opts)
  local job, buf = M.new_tab(nil, opts)
  api.nvim_chan_send(job, command .. "\n")
  return job, buf
end

-- Every tab's record, in tab order. The records are live: read them freely, change
-- them only through M.update so the change is announced.
function M.tabs()
  return tabs
end

-- The record for `buf`, or nil.
function M.record(buf)
  local i = index_of(buf)
  return i and tabs[i] or nil
end

-- The buffer of the tab showing (or last shown), or nil.
function M.current_buf()
  return tabs[current] and tabs[current].buf or nil
end

-- Changes fields on a tab's record and fires FloatTermTabChanged. A new status sets
-- status_since unless given. A field set to vim.NIL is cleared (a nil in the table
-- would simply be skipped).
function M.update(buf, fields)
  local record = M.record(buf)
  if not record then
    return
  end

  local changed = {}
  for key, value in pairs(fields) do
    if value == vim.NIL then
      value = nil
    end
    if record[key] ~= value then
      record[key] = value
      table.insert(changed, key)
    end
  end
  if fields.status ~= nil and vim.tbl_contains(changed, "status") and fields.status_since == nil then
    record.status_since = os.time()
    table.insert(changed, "status_since")
  end
  if #changed == 0 then
    return
  end

  if vim.tbl_contains(changed, "label") and win_is_open() then
    api.nvim_win_set_config(win, { title = title(boxes()), title_pos = "center" })
  end
  fire("FloatTermTabChanged", { buf = buf, id = record.id, fields = changed })
end

-- Shows the tab holding `buf`, opening the float if it's hidden. False if no tab does.
function M.focus_buf(buf)
  local i = index_of(buf)
  if not i then
    return false
  end
  current = i
  show_current()
  return true
end

-- Ends a tab's job; the tab goes when the job exits.
function M.close_tab(buf)
  local record = M.record(buf)
  if record and record.job then
    vim.fn.jobstop(record.job)
  end
end

-- True when the float is open and showing `buf`.
function M.is_showing(buf)
  return win_is_open() and tabs[current] ~= nil and tabs[current].buf == buf
end

function M.is_open()
  return win_is_open()
end

-- The float's window, or nil when it's hidden.
function M.window()
  return win_is_open() and win or nil
end

-- The current boxes (see `boxes`), whether or not the float is open, plus `open` and
-- `full`. lua/floatterm/tabbar draws into `tabbar`.
function M.layout()
  local layout = (placement.split.on and is_split_window(win)) and split_boxes() or boxes()
  layout.split = placement.split.on
  layout.open = win_is_open()
  layout.full = placement.full
  return layout
end

function M.hide()
  hide()
end

function M.next_tab()
  if #tabs < 2 then
    return
  end

  current = current % #tabs + 1
  show_current()
end

-- Moves a tab `delta` places along (-1 earlier, 1 later), stopping at the ends. The
-- tab showing stays showing.
function M.move_tab(buf, delta)
  local from = index_of(buf)
  if not from then
    return
  end
  local to = math.max(1, math.min(#tabs, from + delta))
  if to == from then
    return
  end
  local showing = tabs[current]
  table.insert(tabs, to, table.remove(tabs, from))
  current = index_of(showing.buf) or current
  if win_is_open() and not placement.split.on then
    api.nvim_win_set_config(win, { title = title(boxes()), title_pos = "center" })
  end
  fire "FloatTermTabsChanged"
end

-- Closes the tab showing, for when its program has hung: asks the job to stop, and
-- kills it outright if it's still running a second later. Asks first for a Claude
-- tab, as that one is easy to lose by accident.
function M.close_current()
  local record = tabs[current]
  if not record or not record.job then
    return
  end
  local function close()
    local pid = vim.fn.jobpid(record.job)
    vim.fn.jobstop(record.job)
    vim.defer_fn(function()
      if pid > 0 and vim.uv.kill(pid, 0) == 0 then
        vim.uv.kill(pid, "sigkill")
      end
    end, 1000)
  end
  if record.kind ~= "claude" then
    close()
    return
  end
  vim.ui.select({ "Close it", "Keep it" }, { prompt = "Close the Claude tab " .. M.name(record) .. "?" }, function(choice)
    if choice == "Close it" then
      close()
    end
  end)
end

function M.previous_tab()
  if #tabs < 2 then
    return
  end

  current = (current - 2) % #tabs + 1
  show_current()
end

-- Applies a new placement, opening the float if it's hidden, unless it would leave
-- the terminal too small, in which case nothing changes. Lasts until nvim restarts.
local function place(next)
  if next.split.on then
    local size, horizontal = split_size(next)
    local rows, cols = editor_area()
    if (horizontal and size or rows) < MIN_ROWS or (horizontal and cols or size) < MIN_COLS then
      return
    end
  else
    local box = boxes(next).terminal
    if box.height - 2 < MIN_ROWS or box.width - 2 < MIN_COLS then
      return
    end
  end

  -- A split moving edge or size is simplest closed and opened again; the tabs keep running.
  if placement.split.on and is_split_window(win) and not vim.deep_equal(placement.split, next.split) then
    close_split_windows()
    win = nil
  end
  placement = next
  remember_placement(placement)
  if #tabs == 0 then
    M.new_tab()
  else
    show_current()
  end
end

local STEPS = { left = { 0, -1 }, right = { 0, 1 }, top = { -1, 0 }, bottom = { 1, 0 } }

-- Docked: docks to `direction` at the large size, or flips between large and small
-- if it's already docked there. Floating: moves the box one square that way,
-- stopping at the edge of the grid. Full-screen: leaves it and docks to that edge.
function M.move(direction)
  local step = STEPS[direction]
  if not step then
    vim.notify("floatterm: no direction called " .. direction, vim.log.levels.WARN)
    return
  end

  local next = vim.deepcopy(placement)
  if next.split.on then
    -- As docked: the edge it's on flips its size, another edge moves it there. It keeps
    -- its size when it moves, as a split at 90% would leave little room for the code.
    if next.split.edge == direction then
      next.split.size = next.split.size == "large" and "small" or "large"
    else
      next.split.edge = direction
    end
  elseif next.full then
    next.full = false
    next.mode = "dock"
    next.edge = direction
    next.size = "large"
  elseif next.mode == "dock" then
    if next.edge == direction then
      next.size = next.size == "large" and "small" or "large"
    else
      next.edge = direction
      next.size = "large"
    end
  else
    next.cell.row = math.min(2, math.max(0, next.cell.row + step[1]))
    next.cell.col = math.min(2, math.max(0, next.cell.col + step[2]))
    if vim.deep_equal(next.cell, placement.cell) then
      return
    end
  end

  place(next)
end

-- Switches between docked and the floating box, back to wherever each was last.
-- From full-screen it goes to the box.
function M.switch_mode()
  local next = vim.deepcopy(placement)
  if next.split.on then
    next.split.on = false
    next.full = false
    next.mode = "float"
  elseif next.full then
    next.full = false
    next.mode = "float"
  else
    next.mode = next.mode == "dock" and "float" or "dock"
  end
  place(next)
end

-- Full-screen on or off; off returns to where the float was. Not kept across restarts.
function M.toggle_fullscreen()
  local next = vim.deepcopy(placement)
  next.full = next.split.on or not next.full
  next.split.on = false
  place(next)
end

-- Between the float (where it last was) and a split beside the code.
function M.toggle_split()
  local next = vim.deepcopy(placement)
  next.split.on = not next.split.on
  place(next)
end

-- Shows or hides the key hints until nvim restarts (the setting holds the default).
function M.toggle_hints()
  hints_shown = not hints_shown
  relayout()
end

-- The tab whose Claude has waited longest for you, or nil.
local function waiting_tab()
  local found = nil
  for i, record in ipairs(tabs) do
    if record.status == "needs_you" and (not found or (record.status_since or 0) < (tabs[found].status_since or 0)) then
      found = i
    end
  end
  return found
end

-- Hides the float, or opens it: on a tab that needs you if there is one, else on the
-- tab last shown.
function M.toggle()
  if placement.split.on and is_split_window(win) then
    -- The split stays; this moves between it and the code.
    if api.nvim_get_current_win() ~= win then
      current = waiting_tab() or current
      show_current()
      return
    end
    vim.cmd "wincmd p"
    if api.nvim_get_current_win() == win or api.nvim_get_current_win() == bar_win then
      for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if w ~= win and w ~= bar_win and is_split_window(w) then
          api.nvim_set_current_win(w)
          break
        end
      end
    end
    return
  end

  if win_is_open() then
    hide()
    return
  end

  if #tabs == 0 then
    M.new_tab()
  else
    current = waiting_tab() or current
    show_current()
  end
end

api.nvim_create_user_command("FloatTerm", function(args)
  if args.args == "" then
    M.toggle()
  elseif args.args == "mode" then
    M.switch_mode()
  elseif args.args == "full" then
    M.toggle_fullscreen()
  elseif args.args == "split" then
    M.toggle_split()
  else
    M.move(args.args)
  end
end, {
  nargs = "?",
  complete = function()
    return { "left", "right", "top", "bottom", "mode", "full", "split" }
  end,
  desc = "Toggle the floating terminal, move it (as Ctrl+Shift+arrows), switch mode or go full-screen",
})

-- Closing the float some other way (:q, say) takes the hints with it.
api.nvim_create_autocmd("WinClosed", {
  callback = function(args)
    local closed = tonumber(args.match)
    if bar_win and closed == bar_win then
      bar_win = nil
    end
    if win and closed == win then
      close_hints()
      win = nil
      -- The bar's window means nothing without the split beside it. Only that bar: by
      -- the time this runs a new split may have opened with a bar of its own, so the
      -- event says whether the terminal is open then rather than assuming not.
      local orphan = bar_win
      vim.schedule(function()
        if orphan and api.nvim_win_is_valid(orphan) and orphan ~= bar_win then
          pcall(api.nvim_win_close, orphan, true)
        elseif orphan and orphan == bar_win and not win_is_open() then
          pcall(api.nvim_win_close, orphan, true)
          bar_win = nil
        end
        fire("FloatTermLayoutChanged", { open = win_is_open() })
      end)
    end
  end,
})

api.nvim_create_autocmd("VimResized", { callback = relayout })
-- The split's bar window is only somewhere for the tab bar to draw; moving into it
-- (Ctrl+w, a click) lands in the terminal instead.
api.nvim_create_autocmd("WinEnter", {
  callback = function()
    if bar_win and api.nvim_get_current_win() == bar_win and is_split_window(win) then
      vim.schedule(function()
        if api.nvim_win_is_valid(win) then
          api.nvim_set_current_win(win)
        end
      end)
    end
  end,
})
-- The tab line coming or going moves the area the float sits in.
api.nvim_create_autocmd({ "TabEnter", "TabClosed" }, { callback = relayout })
api.nvim_create_autocmd("OptionSet", { pattern = "showtabline", callback = relayout })

api.nvim_create_autocmd("User", {
  pattern = "FloatTermSettingsChanged",
  callback = function(args)
    if args.data.key == "hints" then
      hints_shown = settings.get "hints"
    end
    relayout()
  end,
})

api.nvim_create_autocmd("TermClose", {
  callback = function(args)
    if not index_of(args.buf) then
      return
    end

    vim.schedule(function()
      -- Found again here rather than before scheduling: another tab may have closed in
      -- between and shifted the positions.
      local index = index_of(args.buf)
      if index then
        table.remove(tabs, index)
        if #tabs == 0 then
          current = 0
          hide()
        else
          if current >= index then
            current = math.max(current - 1, 1)
          end
          -- Swap the window onto another tab first; deleting the buffer it shows
          -- would close the float.
          if win_is_open() then
            show_current()
          end
        end
        fire "FloatTermTabsChanged"
      end

      if api.nvim_buf_is_valid(args.buf) then
        api.nvim_buf_delete(args.buf, { force = true })
      end
    end)
  end,
})

return M
