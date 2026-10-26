-- The floating terminal's options panel, like the panel <leader> brings up:
-- Ctrl+Shift+Space in a tab shows every action with its key in the middle of the screen, and the next
-- plain key runs one. Esc, or a key that isn't listed, closes it and does nothing.

local M = {}

local api = vim.api

local function floatterm()
  return require "floatterm"
end

local function go_to_tab(n)
  return function()
    local record = floatterm().tabs()[n]
    if record then
      floatterm().focus_buf(record.buf)
    end
  end
end

-- Two columns, top to bottom. Each entry is { keys shown, what it does, { key = action } }.
M.columns = {
  {
    { "d", "split ↔ float", { d = function() floatterm().toggle_split() end } },
    { "f", "full-screen", { f = function() floatterm().toggle_fullscreen() end } },
    { "g", "dock ↔ box", { g = function() floatterm().switch_mode() end } },
    {
      "h j k l",
      "move / resize",
      {
        h = function() floatterm().move "left" end,
        j = function() floatterm().move "bottom" end,
        k = function() floatterm().move "top" end,
        l = function() floatterm().move "right" end,
      },
    },
    { "s", "settings", { s = function() require("floatterm.config_page").open() end } },
    { "q", "hide", { q = function() floatterm().toggle() end } },
  },
  {
    { "t", "new tab", { t = function() floatterm().new_tab() end } },
    { "n", "next tab", { n = function() floatterm().next_tab() end } },
    { "p", "previous tab", { p = function() floatterm().previous_tab() end } },
    { "b", "tab bar", { b = function() require("floatterm.tabbar").enter() end } },
    {
      "1-9",
      "go to tab",
      (function()
        local keys = {}
        for n = 1, 9 do
          keys[tostring(n)] = go_to_tab(n)
        end
        return keys
      end)(),
    },
  },
}

-- The panel's lines, and where each key sits in them (row, first byte, last byte) so
-- the keys can stand out from what they do.
local function lines()
  local key_width, text_width = 0, 0
  for _, column in ipairs(M.columns) do
    for _, entry in ipairs(column) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
      text_width = math.max(text_width, vim.fn.strdisplaywidth(entry[2]))
    end
  end

  local function pad(text, width)
    return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
  end

  local out, keys = {}, {}
  for i = 1, math.max(#M.columns[1], #M.columns[2]) do
    local line = " "
    for c, column in ipairs(M.columns) do
      local entry = column[i]
      if c > 1 then
        line = line .. "    "
      end
      if entry then
        table.insert(keys, { i - 1, #line, #line + #entry[1] })
        line = line .. pad(entry[1], key_width) .. "  " .. pad(entry[2], text_width)
      else
        line = line .. string.rep(" ", key_width + 2 + text_width)
      end
    end
    out[i] = line .. " "
  end
  return out, keys
end

local function action_for(key)
  for _, column in ipairs(M.columns) do
    for _, entry in ipairs(column) do
      if entry[3][key] then
        return entry[3][key]
      end
    end
  end
  return nil
end

-- Shows the panel, waits for one key and runs its action.
function M.open()
  local text, keys = lines()
  local width = vim.fn.strdisplaywidth(text[1])
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, text)

  local namespace = api.nvim_create_namespace "floatterm_menu"
  for _, key in ipairs(keys) do
    vim.highlight.range(buf, namespace, "Keyword", { key[1], key[2] }, { key[1], key[3] })
  end

  local panel = api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.floor((vim.o.lines - #text) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #text,
    style = "minimal",
    border = "rounded",
    title = " Terminal ",
    title_pos = "center",
    footer = " Esc closes ",
    footer_pos = "center",
    focusable = false,
    zindex = 250,
    noautocmd = true,
  })
  vim.cmd.redraw()

  local ok, key = pcall(vim.fn.getcharstr)
  if api.nvim_win_is_valid(panel) then
    api.nvim_win_close(panel, true)
  end
  local action = ok and action_for(key) or nil
  if action then
    action()
  end
end

return M
