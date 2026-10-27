-- The floating terminal's actions, each with a plain key: listed under <leader>o for
-- which-key, and in a panel that Ctrl+Shift+Space opens in a tab (where the terminal app
-- passes that key on). Each shows its direct shortcut too, so the listing teaches the
-- keys it saves you.

local M = {}

local api = vim.api

local function floatterm()
  return require "floatterm"
end

local function notes()
  return require "floatterm.notes"
end

local function go_to_tab(n)
  return function()
    local record = floatterm().tabs()[n]
    if record then
      floatterm().focus_buf(record.buf)
    end
  end
end

-- Two columns, top to bottom. Each entry is { keys shown, what it does, { key = action },
-- direct shortcut }. The shortcut does the same from inside a terminal tab, and is shown
-- beside the action so it can be learnt; a table gives one per key.
M.columns = {
  {
    { "d", "split ↔ float", { d = function() floatterm().toggle_split() end }, "Ctrl+Shift+d" },
    { "f", "full-screen", { f = function() floatterm().toggle_fullscreen() end }, "Ctrl+Shift+f" },
    { "g", "dock ↔ box", { g = function() floatterm().switch_mode() end }, "Ctrl+Shift+g" },
    {
      "h j k l",
      "move / resize",
      {
        h = function() floatterm().move "left" end,
        j = function() floatterm().move "bottom" end,
        k = function() floatterm().move "top" end,
        l = function() floatterm().move "right" end,
      },
      { h = "Ctrl+Shift+h", j = "Ctrl+Shift+j", k = "Ctrl+Shift+k", l = "Ctrl+Shift+l" },
      { h = "move left / resize", j = "move down / resize", k = "move up / resize", l = "move right / resize" },
    },
    { "s", "settings", { s = function() require("floatterm.config_page").open() end }, "Ctrl+Shift+," },
    { "q", "hide or show", { q = function() floatterm().toggle() end }, "Ctrl+\\" },
    { "e", "notes on / off", { e = function() notes().toggle_notes() end } },
    { "i", "into notes ↔ terminal", { i = function() notes().toggle_focus() end }, "Ctrl+Shift+e" },
    { "a", "add a note", { a = function() notes().add_note() end } },
  },
  {
    { "t", "new tab", { t = function() floatterm().new_tab() end }, "Ctrl+t" },
    { "n", "next tab", { n = function() floatterm().next_tab() end }, "Ctrl+Shift+n" },
    { "p", "previous tab", { p = function() floatterm().previous_tab() end }, "Ctrl+Shift+p" },
    { "b", "tab bar", { b = function() require("floatterm.tabbar").enter() end }, "Ctrl+Shift+b" },
    {
      "< >",
      "move tab earlier / later",
      {
        ["<"] = function() floatterm().move_tab(floatterm().current_buf(), -1) end,
        [">"] = function() floatterm().move_tab(floatterm().current_buf(), 1) end,
      },
      { ["<"] = "Ctrl+Opt+←", [">"] = "Ctrl+Opt+→", all = "Ctrl+Opt+←/→" },
      { ["<"] = "move tab earlier", [">"] = "move tab later" },
    },
    { "x", "close tab (force)", { x = function() floatterm().close_current() end } },
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
    { "y", "selection to notes", { y = function() notes().capture() end }, "Y in a tab" },
    { "o", "earlier notes", { o = function() notes().pick() end } },
    { "r", "refresh Claude's notes", { r = function() require("floatterm.claude_notes").refresh() end } },
  },
}

-- What an entry does, with its shortcut: "split ↔ float (Ctrl+Shift+d)". Given one of
-- several keys (h of h j k l), that key's own shortcut; for the whole entry, all of
-- them together ("Ctrl+Shift+h/j/k/l").
local function describe(entry, key)
  local shortcut = entry[4]
  if type(shortcut) == "table" then
    if key then
      shortcut = shortcut[key]
    else
      local keys = vim.split(entry[1], " ")
      shortcut = shortcut.all or (shortcut[keys[1]]:gsub("%w$", "") .. table.concat(keys, "/"))
    end
  end
  -- An optional fifth field names each key's action on its own.
  local text = key and entry[5] and entry[5][key] or entry[2]
  return shortcut and (text .. " (" .. shortcut .. ")") or text
end

-- The panel's lines, and where each key sits in them (row, first byte, last byte) so
-- the keys can stand out from what they do.
local function lines()
  local key_width, text_width = 0, 0
  for _, column in ipairs(M.columns) do
    for _, entry in ipairs(column) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
      text_width = math.max(text_width, vim.fn.strdisplaywidth(describe(entry)))
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
        line = line .. pad(entry[1], key_width) .. "  " .. pad(describe(entry), text_width)
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

-- The same actions under <leader>o, so the which-key panel lists them like any other
-- leader group. From a terminal tab, Ctrl+x first to leave typing.
function M.setup()
  for _, column in ipairs(M.columns) do
    for _, entry in ipairs(column) do
      for key, action in pairs(entry[3]) do
        local desc = entry[1] == "1-9" and ("go to tab " .. key) or describe(entry, key)
        vim.keymap.set("n", "<leader>o" .. key, action, { desc = desc })
      end
    end
  end
  pcall(function()
    require("which-key").add { { "<leader>o", group = "terminal" } }
  end)
end

return M
