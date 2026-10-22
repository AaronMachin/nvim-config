-- Floating terminal with tabs.
--
-- One float window shows one of several shell buffers at a time. The border title
-- lists the tabs and marks the one showing. Hiding the float leaves every shell
-- running; it reopens on the tab last shown. A tab closes when its shell exits.
--
-- The float is either docked to an edge of the editor or floating in one square of
-- a 3x3 grid. A line of key hints sits in the gap above or below it, or in its
-- bottom border when there's no gap.

local M = {}

local api = vim.api

local bufs = {}
-- Optional short names shown next to a tab's number, keyed by buffer.
local labels = {}
local current = 0
local win = nil
local hint_win = nil
local hint_buf = nil
local hints_shown = true

-- Where the float is. Docked, `edge` and `size` apply; floating, `cell` does (0-2 each
-- way, starting in the centre). Both are kept so switching back returns to the last spot.
local placement = { mode = "dock", edge = "bottom", size = "large", cell = { row = 1, col = 1 } }

local HINTS = "Ctrl+\\ hide · Ctrl+t new tab · Ctrl+| next tab · Ctrl+x scroll/copy, i to type · Ctrl+Shift+arrows move/resize · Ctrl+Shift+m dock/float · Ctrl+Shift+h hide hints"
-- For when the full line won't fit, such as the bottom border of a narrow float.
local SHORT_HINTS = "C-\\ hide · C-t tab · C-| next · C-x copy · C-S-arrows move · C-S-m mode · C-S-h hints"

-- The full hints if they fit in `width` columns with a space either side, else the short ones.
local function hints_for(width)
  return vim.fn.strdisplaywidth(HINTS) + 2 <= width and HINTS or SHORT_HINTS
end

-- A cell is about twice as tall as it is wide, so 2 columns looks like 1 row.
local SIDE_GAP = 2
local EDGE_GAP = 1
-- Docked, the float takes this share of the editor's height (top/bottom) or width (left/right).
local DOCK_SIZES = { large = 0.9, small = 0.2 }
-- A move that would leave the terminal smaller than this does nothing.
local MIN_ROWS = 5
local MIN_COLS = 20

-- The float's outer box (border included) for a placement, in an editor area of
-- `rows` x `cols`.
local function geometry(p, rows, cols)
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

  if p.edge == "top" or p.edge == "bottom" then
    local share = math.floor(rows * DOCK_SIZES[p.size])
    return {
      row = p.edge == "top" and EDGE_GAP or rows - share,
      col = SIDE_GAP,
      height = share - EDGE_GAP,
      width = cols - 2 * SIDE_GAP,
    }
  end

  local share = math.floor(cols * DOCK_SIZES[p.size])
  return {
    row = EDGE_GAP,
    col = p.edge == "left" and SIDE_GAP or cols - share,
    height = rows - 2 * EDGE_GAP,
    width = share - SIDE_GAP,
  }
end

-- The editor rows a float can use: everything above the statusline.
local function editor_area()
  return vim.o.lines - vim.o.cmdheight - 1, vim.o.columns
end

local function box()
  return geometry(placement, editor_area())
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

local function title()
  local names = {}
  for i, buf in ipairs(bufs) do
    local name = labels[buf] and (i .. " " .. labels[buf]) or tostring(i)
    names[i] = i == current and ("[" .. name .. "]") or name
  end
  return " " .. table.concat(names, " │ ") .. " "
end

local function float_config()
  local outer = box()
  local in_footer = hints_shown and hints_row(outer, (editor_area())) == nil

  -- The border adds a row above and below, and a column either side.
  local config = {
    relative = "editor",
    border = "rounded",
    row = outer.row,
    col = outer.col,
    height = outer.height - 2,
    width = outer.width - 2,
    title = title(),
    title_pos = "center",
    footer = in_footer and (" " .. hints_for(outer.width - 2) .. " ") or "",
    footer_pos = "center",
  }
  return config
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
  local outer = box()
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

-- Puts the current tab's buffer in the float, opening the float if it's hidden.
local function show_current()
  local buf = bufs[current]

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
end

local function hide()
  close_hints()
  if win_is_open() then
    api.nvim_win_close(win, true)
  end
  win = nil
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
  map("<C-S-h>", M.toggle_hints, "terminal show or hide key hints")
end

-- Opens a tab running `argv` (a shell by default). The tab closes when it exits.
-- opts: cwd and env for the job, and label, a short name shown in the title.
-- Returns the tab's terminal job id and its buffer.
function M.new_tab(argv, opts)
  opts = opts or {}
  local buf = api.nvim_create_buf(false, true)
  table.insert(bufs, buf)
  labels[buf] = opts.label
  current = #bufs

  show_current()
  local job
  api.nvim_buf_call(buf, function()
    -- A bare { shell } is deleted by Neovim's own TermClose handler before ours
    -- runs, taking the float with it. -i is what the shell would be anyway.
    -- detach is set so the table is never empty, which termopen would read as a list.
    job = vim.fn.termopen(type(argv) == "table" and argv or { vim.o.shell, "-i" }, {
      detach = false,
      cwd = opts.cwd,
      env = opts.env,
    })
  end)
  map_tab_keys(buf)
  -- termopen renames the buffer, so the title is set again after it.
  show_current()
  return job, buf
end

-- Opens a shell tab and types `command` into it, so the shell stays open afterwards
-- with the output to read. opts as for new_tab.
function M.run_in_tab(command, opts)
  local job, buf = M.new_tab(nil, opts)
  api.nvim_chan_send(job, command .. "\n")
  return job, buf
end

-- Shows the tab holding `buf`, opening the float if it's hidden. False if no tab does.
function M.focus_buf(buf)
  for i, tab_buf in ipairs(bufs) do
    if tab_buf == buf then
      current = i
      show_current()
      return true
    end
  end
  return false
end

-- True when the float is open and showing `buf`.
function M.is_showing(buf)
  return win_is_open() and bufs[current] == buf
end

function M.hide()
  hide()
end

function M.next_tab()
  if #bufs < 2 then
    return
  end

  current = current % #bufs + 1
  show_current()
end

-- Applies a new placement, opening the float if it's hidden, unless it would leave
-- the terminal too small, in which case nothing changes. Lasts until nvim restarts.
local function place(next)
  local outer = geometry(next, editor_area())
  if outer.height - 2 < MIN_ROWS or outer.width - 2 < MIN_COLS then
    return
  end

  placement = next
  if #bufs == 0 then
    M.new_tab()
  else
    show_current()
  end
end

local STEPS = { left = { 0, -1 }, right = { 0, 1 }, top = { -1, 0 }, bottom = { 1, 0 } }

-- Docked: docks to `direction` at the large size, or flips between large and small
-- if it's already docked there. Floating: moves the box one square that way,
-- stopping at the edge of the grid.
function M.move(direction)
  local step = STEPS[direction]
  if not step then
    vim.notify("floatterm: no direction called " .. direction, vim.log.levels.WARN)
    return
  end

  local next = vim.deepcopy(placement)
  if next.mode == "dock" then
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
function M.switch_mode()
  local next = vim.deepcopy(placement)
  next.mode = next.mode == "dock" and "float" or "dock"
  place(next)
end

-- Shows or hides the key hints. Lasts until nvim restarts.
function M.toggle_hints()
  hints_shown = not hints_shown
  if win_is_open() then
    api.nvim_win_set_config(win, float_config())
    show_hints()
  end
end

function M.toggle()
  if win_is_open() then
    hide()
    return
  end

  if #bufs == 0 then
    M.new_tab()
  else
    show_current()
  end
end

api.nvim_create_user_command("FloatTerm", function(args)
  if args.args == "" then
    M.toggle()
  elseif args.args == "mode" then
    M.switch_mode()
  else
    M.move(args.args)
  end
end, {
  nargs = "?",
  complete = function()
    return { "left", "right", "top", "bottom", "mode" }
  end,
  desc = "Toggle the floating terminal, move it (as Ctrl+Shift+arrows), or switch mode",
})

-- Closing the float some other way (:q, say) takes the hints with it.
api.nvim_create_autocmd("WinClosed", {
  callback = function(args)
    if win and tonumber(args.match) == win then
      close_hints()
      win = nil
    end
  end,
})

api.nvim_create_autocmd("VimResized", {
  callback = function()
    if win_is_open() then
      api.nvim_win_set_config(win, float_config())
      show_hints()
    end
  end,
})

api.nvim_create_autocmd("TermClose", {
  callback = function(args)
    local index = nil
    for i, buf in ipairs(bufs) do
      if buf == args.buf then
        index = i
      end
    end
    if not index then
      return
    end

    vim.schedule(function()
      table.remove(bufs, index)
      labels[args.buf] = nil

      if #bufs == 0 then
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

      if api.nvim_buf_is_valid(args.buf) then
        api.nvim_buf_delete(args.buf, { force = true })
      end
    end)
  end,
})

return M
