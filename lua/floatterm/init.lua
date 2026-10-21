-- Floating terminal with tabs.
--
-- One float window shows one of several shell buffers at a time. The border title
-- lists the tabs and marks the one showing. Hiding the float leaves every shell
-- running; it reopens on the tab last shown. A tab closes when its shell exits.
--
-- The float can sit in one of several layouts (bottom by default), and a line of
-- key hints sits in the gap beside it, or in its bottom border when there's no gap.

local M = {}

local api = vim.api

local bufs = {}
local current = 0
local win = nil
local hint_win = nil
local hint_buf = nil
local layout = "bottom"
local hints_shown = true

local HINTS = "Ctrl+\\ hide · Ctrl+t new tab · Ctrl+| next tab · Ctrl+x scroll/copy, i to type · Ctrl+Shift+arrows/m move · Ctrl+Shift+h hide hints"
-- For when the full line won't fit, such as the bottom border of a half-width float.
local SHORT_HINTS = "C-\\ hide · C-t tab · C-| next · C-x copy · C-S-arrows/m move · C-S-h hints"

-- The full hints if they fit in `width` columns with a space either side, else the short ones.
local function hints_for(width)
  return vim.fn.strdisplaywidth(HINTS) + 2 <= width and HINTS or SHORT_HINTS
end

-- A cell is about twice as tall as it is wide, so 2 columns looks like 1 row.
local SIDE_GAP = 2
local EDGE_GAP = 1
local WIDE_GAP = 0.1
local MIDDLE_SIZE = 0.8

-- Each layout gives the float's outer box (border included) and where the hints go:
-- the gap above it, the gap below it, or its bottom border.
local layouts = {
  bottom = function(rows, cols)
    local top = math.floor(rows * WIDE_GAP)
    return { row = top, col = SIDE_GAP, height = rows - top - EDGE_GAP, width = cols - 2 * SIDE_GAP, hints = "above" }
  end,
  top = function(rows, cols)
    local bottom = math.floor(rows * WIDE_GAP)
    return { row = EDGE_GAP, col = SIDE_GAP, height = rows - bottom - EDGE_GAP, width = cols - 2 * SIDE_GAP, hints = "below" }
  end,
  left = function(rows, cols)
    return { row = EDGE_GAP, col = SIDE_GAP, height = rows - 2 * EDGE_GAP, width = math.floor(cols / 2) - SIDE_GAP, hints = "footer" }
  end,
  right = function(rows, cols)
    local width = math.floor(cols / 2) - SIDE_GAP
    return { row = EDGE_GAP, col = cols - SIDE_GAP - width, height = rows - 2 * EDGE_GAP, width = width, hints = "footer" }
  end,
  middle = function(rows, cols)
    local height = math.floor(rows * MIDDLE_SIZE)
    local width = math.floor(cols * MIDDLE_SIZE)
    return {
      row = math.floor((rows - height) / 2),
      col = math.floor((cols - width) / 2),
      height = height,
      width = width,
      hints = "above",
    }
  end,
}

M.layouts = vim.tbl_keys(layouts)

local function win_is_open()
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function title()
  local labels = {}
  for i = 1, #bufs do
    labels[i] = i == current and ("[" .. i .. "]") or tostring(i)
  end
  return " " .. table.concat(labels, " │ ") .. " "
end

-- The editor rows a float can use: everything above the statusline.
local function box()
  return layouts[layout](vim.o.lines - vim.o.cmdheight - 1, vim.o.columns)
end

local function float_config()
  local outer = box()

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
    footer = hints_shown and outer.hints == "footer" and (" " .. hints_for(outer.width - 2) .. " ") or "",
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

-- Shows the hints line in the gap above or below the float, centred on it.
local function show_hints()
  close_hints()

  local outer = box()
  local row = outer.hints == "above" and outer.row - 1 or outer.row + outer.height
  if not hints_shown or outer.hints == "footer" or row < 0 then
    return
  end

  if not (hint_buf and api.nvim_buf_is_valid(hint_buf)) then
    hint_buf = api.nvim_create_buf(false, true)
  end
  local hints = hints_for(outer.width)
  api.nvim_buf_set_lines(hint_buf, 0, -1, false, { hints })

  local width = math.min(vim.fn.strdisplaywidth(hints), outer.width)
  hint_win = api.nvim_open_win(hint_buf, false, {
    relative = "editor",
    row = row,
    col = outer.col + math.floor((outer.width - width) / 2),
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
  map("<C-S-Left>", function() M.move "left" end, "terminal move float left")
  map("<C-S-Right>", function() M.move "right" end, "terminal move float right")
  map("<C-S-Up>", function() M.move "top" end, "terminal move float to top")
  map("<C-S-Down>", function() M.move "bottom" end, "terminal move float to bottom")
  map("<C-S-m>", function() M.move "middle" end, "terminal move float to middle")
  map("<C-S-h>", M.toggle_hints, "terminal show or hide key hints")
end

function M.new_tab()
  local buf = api.nvim_create_buf(false, true)
  table.insert(bufs, buf)
  current = #bufs

  show_current()
  api.nvim_buf_call(buf, function()
    -- A bare { shell } is deleted by Neovim's own TermClose handler before ours
    -- runs, taking the float with it. -i is what the shell would be anyway.
    vim.fn.termopen { vim.o.shell, "-i" }
  end)
  map_tab_keys(buf)
  -- termopen renames the buffer, so the title is set again after it.
  show_current()
end

function M.next_tab()
  if #bufs < 2 then
    return
  end

  current = current % #bufs + 1
  show_current()
end

-- Moves the float to a layout, opening it if it's hidden. Lasts until nvim restarts.
function M.move(name)
  if not layouts[name] then
    vim.notify("floatterm: no layout called " .. name, vim.log.levels.WARN)
    return
  end

  layout = name
  if #bufs == 0 then
    M.new_tab()
  else
    show_current()
  end
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
  else
    M.move(args.args)
  end
end, {
  nargs = "?",
  complete = function()
    return M.layouts
  end,
  desc = "Toggle the floating terminal, or move it to a layout",
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
