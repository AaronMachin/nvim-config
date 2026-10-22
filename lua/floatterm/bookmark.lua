-- The Claude sessions bookmark: a small mark in the top right of the editor for each
-- Claude tab, in tab order and in the tab bar's colours (● needs you, ◌ working,
-- ✓ done), so you can see one wants you without opening the float.
--
-- It shows whether or not the float is open, sits above every other window and can't
-- be focused. It hides when there are no Claude tabs, and when the bookmark setting is
-- off (toggle it with M.toggle).

local M = {}

local api = vim.api
local settings = require "floatterm.settings"
local tabbar = require "floatterm.tabbar"

local ns = api.nvim_create_namespace "floatterm_bookmark"
local win = nil
local buf = nil

local function close()
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  win = nil
end

-- The marks as { text, hl } pairs, one per Claude tab.
local function marks()
  local floatterm = package.loaded["floatterm"]
  local found = {}
  for _, record in ipairs(floatterm and floatterm.tabs() or {}) do
    if record.kind == "claude" then
      local state = tabbar.state(record)
      table.insert(found, { state.glyph, state.hl })
    end
  end
  return found
end

-- Where the bookmark goes, as editor row and column: in the top right, below the tab
-- line when there is one (NvChad's buffer line uses that row). When the float covers
-- that spot (full-screen, say), it sits in the terminal's top border instead, just
-- left of the corner and clear of a tab bar along the top.
local function spot(width)
  local tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)
  local row = tabline and 1 or 0
  local col = math.max(0, vim.o.columns - width - 1)

  local floatterm = package.loaded["floatterm"]
  local float = floatterm and floatterm.window()
  if not (float and api.nvim_win_get_tabpage(float) == api.nvim_get_current_tabpage()) then
    return row, col
  end
  local layout = floatterm.layout()
  local outer, terminal = layout.outer, layout.terminal
  local overlaps = row >= outer.row
    and row < outer.row + outer.height
    and col < outer.col + outer.width
    and col + width > outer.col
  if not overlaps then
    return row, col
  end
  return terminal.row, math.max(terminal.col + 1, terminal.col + terminal.width - width - 2)
end

function M.redraw()
  local found = marks()
  if not settings.get "bookmark" or #found == 0 then
    close()
    return
  end

  local text, spans = "", {}
  for _, mark in ipairs(found) do
    text = text .. " "
    table.insert(spans, { #text, #text + #mark[1], mark[2] })
    text = text .. mark[1]
  end
  text = text .. " "

  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, span in ipairs(spans) do
    api.nvim_buf_set_extmark(buf, ns, 0, span[1], { end_col = span[2], hl_group = span[3] })
  end

  local width = vim.fn.strdisplaywidth(text)
  local row, col = spot(width)
  local config = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    zindex = 250,
    focusable = false,
  }
  -- A float shows only on the tab page it was opened on, so on another one it's
  -- opened again there.
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage() then
    close()
  end
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_config(win, config)
  else
    config.style = "minimal"
    config.noautocmd = true
    win = api.nvim_open_win(buf, false, config)
    vim.wo[win].winhighlight = "Normal:NormalFloat"
  end
end

-- The bookmark's text, or nil when it's hidden. For tests and debugging.
function M.text()
  if not (win and api.nvim_win_is_valid(win)) then
    return nil
  end
  return api.nvim_buf_get_lines(buf, 0, -1, false)[1]
end

-- Shows or hides the bookmark, for this nvim and the next (it's the bookmark setting).
function M.toggle()
  settings.set("bookmark", not settings.get "bookmark")
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true

  local group = api.nvim_create_augroup("floatterm_bookmark", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FloatTermLayoutChanged", "FloatTermTabsChanged", "FloatTermTabChanged", "FloatTermSettingsChanged" },
    callback = vim.schedule_wrap(M.redraw),
  })
  -- The tab line coming or going moves it, and another tab page needs its own.
  api.nvim_create_autocmd({ "VimResized", "TabNew", "TabEnter", "TabClosed" }, {
    group = group,
    callback = vim.schedule_wrap(M.redraw),
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "showtabline",
    callback = vim.schedule_wrap(M.redraw),
  })
end

return M
