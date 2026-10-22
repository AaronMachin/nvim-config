-- Floating terminal with tabs.
--
-- One float window shows one of several terminal buffers at a time. Hiding the float
-- leaves every tab running; it reopens on the tab last shown, or on a tab whose Claude
-- needs you. A tab closes when its job exits.
--
-- The float is docked to an edge of the editor, floating in one square of a 3x3 grid,
-- or full-screen. A line of key hints sits in the gap above or below it, or in its
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
local hint_win = nil
local hint_buf = nil
local hints_shown = settings.get "hints"
-- Keys added by other modules for every tab buffer: { lhs, fn, desc }.
local extra_keys = {}

local function start_placement()
  local start = settings.get "start_position"
  local placement = { mode = "dock", edge = "bottom", size = "large", cell = { row = 1, col = 1 }, full = false }
  if start == "box" then
    placement.mode = "float"
  elseif start == "top" or start == "left" or start == "right" then
    placement.edge = start
  end
  return placement
end

-- Where the float is. Docked, `edge` and `size` apply; floating, `cell` does (0-2 each
-- way, starting in the centre). Both are kept so switching back returns to the last
-- spot, and `full` sits on top of either.
local placement = start_placement()

local HINTS = "Ctrl+\\ hide · Ctrl+t new tab · Ctrl+| next tab · Ctrl+x scroll/copy, i to type · Ctrl+Shift+arrows move/resize · Ctrl+Shift+m dock/float · Ctrl+Shift+f full-screen · Ctrl+Shift+h hide hints"
-- For when the full line won't fit, such as the bottom border of a narrow float.
local SHORT_HINTS = "C-\\ hide · C-t tab · C-| next · C-x copy · C-S-arrows move · C-S-m mode · C-S-f full · C-S-h hints"

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

-- The editor rows a float can use: everything above the statusline.
local function editor_area()
  return vim.o.lines - vim.o.cmdheight - 1, vim.o.columns
end

-- Boxes for a placement (current by default), border included: outer is the whole
-- float, terminal the terminal window, tabbar the tab bar's share (nil when off).
local function boxes(p)
  local outer = geometry(p or placement, editor_area())
  local parts = split(outer)
  return { outer = outer, terminal = parts.terminal, tabbar = parts.tabbar }
end

-- Where the hints line goes: the row above the float, the row below it, or (with
-- neither free) its bottom border.
local function hints_row(outer, rows)
  if outer.row >= 1 then
    return outer.row - 1
  end
  if outer.row + outer.height < rows then
    return outer.row + outer.height
  end
  return nil
end

local function win_is_open()
  return win ~= nil and api.nvim_win_is_valid(win)
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
  local in_footer = hints_shown and hints_row(layout.outer, (editor_area())) == nil

  -- The border adds a row above and below, and a column either side.
  return {
    relative = "editor",
    border = "rounded",
    row = box.row,
    col = box.col,
    height = box.height - 2,
    width = box.width - 2,
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

  local rows, cols = editor_area()
  local outer = boxes().outer
  local row = hints_row(outer, rows)
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
  if win_is_open() then
    api.nvim_win_set_config(win, float_config())
    show_hints()
  end
  fire("FloatTermLayoutChanged", { open = win_is_open() })
end

-- Puts the current tab's buffer in the float, opening the float if it's hidden.
local function show_current()
  local buf = tabs[current].buf

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
  if win_is_open() then
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
  map("<C-S-\\>", M.next_tab, "terminal next tab")
  map("<C-S-Left>", function() M.move "left" end, "terminal dock left or move box left")
  map("<C-S-Right>", function() M.move "right" end, "terminal dock right or move box right")
  map("<C-S-Up>", function() M.move "top" end, "terminal dock top or move box up")
  map("<C-S-Down>", function() M.move "bottom" end, "terminal dock bottom or move box down")
  map("<C-S-m>", M.switch_mode, "terminal switch between docked and floating box")
  map("<C-S-f>", M.toggle_fullscreen, "terminal full-screen on or off")
  map("<C-S-h>", M.toggle_hints, "terminal show or hide key hints")
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
  local env = vim.tbl_extend("force", opts.env or {}, { FLOATTERM_TAB_ID = tostring(record.id) })
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
  local layout = boxes()
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

-- Applies a new placement, opening the float if it's hidden, unless it would leave
-- the terminal too small, in which case nothing changes. Lasts until nvim restarts.
local function place(next)
  local box = boxes(next).terminal
  if box.height - 2 < MIN_ROWS or box.width - 2 < MIN_COLS then
    return
  end

  placement = next
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
  if next.full then
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
  if next.full then
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
  next.full = not next.full
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
  else
    M.move(args.args)
  end
end, {
  nargs = "?",
  complete = function()
    return { "left", "right", "top", "bottom", "mode", "full" }
  end,
  desc = "Toggle the floating terminal, move it (as Ctrl+Shift+arrows), switch mode or go full-screen",
})

-- Closing the float some other way (:q, say) takes the hints with it.
api.nvim_create_autocmd("WinClosed", {
  callback = function(args)
    if win and tonumber(args.match) == win then
      close_hints()
      win = nil
      vim.schedule(function()
        fire("FloatTermLayoutChanged", { open = false })
      end)
    end
  end,
})

api.nvim_create_autocmd("VimResized", { callback = relayout })

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
