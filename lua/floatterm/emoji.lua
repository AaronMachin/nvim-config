-- An emoji for every tab, so tabs are easier to tell apart in the tab bar.
--
-- Each tab gets a random one from SET when it first shows, Claude and shell alike, and
-- no two tabs share one: that's what makes them worth having. If two tabs end up with
-- the same one (restored from before this rule, say), the one further down the bar
-- gets a new one, as does a tab whose emoji isn't in SET any more. Only with more tabs
-- than SET has emoji can two match. Group headings get none.
--
-- With the tab_icons setting at "symbols", each tab shows a coloured shape instead
-- (● ■ ▲ ◆ ★ ♥ ♠ ♣ in 8 colours), worked out from its emoji, for terminals whose font
-- draws emoji badly. They're never two the same either, up to 64 tabs.
--
-- On Linux, nvim says once on start when there's no colour emoji font, which is what
-- makes emoji show as outlines or not at all; bin/fix-emoji-font sorts that out.
--
-- The emoji is kept on the tab's record (emoji), and lua/floatterm/restore saves it
-- with the tab, so it's the same when tabs reopen.

local M = {}

local api = vim.api

-- Easy to tell apart at a glance, each one character two columns wide (no variation
-- selectors, none that terminals show narrow), and all from Unicode 11 (2018) or
-- earlier, so fonts a few years old have them.
M.SET = {
  "🦊", "🐙", "🌵", "🍋", "🐝", "🦉", "🍄", "🌻", "🐢", "🦀", "🍉", "🎈", "🧩", "🎲",
  "🚀", "🌙", "🔥", "🌊", "🍀", "🐳", "🦋", "🍒", "🥑", "🎯", "🧲", "🔔", "🌈", "🐌",
  "🦔", "🍩", "🎸", "🛶", "🏮", "🧸", "🦜", "⭐", "⚡", "🦄", "🦢", "🐧", "🐸", "🐼",
  "🐨", "🦁", "🐯", "🦒", "🦓", "🐘", "🦚", "🐞", "🦞", "🐠", "🍓", "🍍", "🥝", "🥕",
  "🌽", "🍕", "🧁", "🍪", "🥨", "🧀", "🍇", "🍑", "🎺", "🎻", "🥁", "🎨", "🎭", "🛸",
  "🚂", "⛵", "🏰", "🗿", "💎", "🔮", "🧭", "🏆", "🌋", "🌷", "🌲", "🍁", "🌀", "🧿",
  "🐉",
}

-- The shapes and colours for symbols, 8 of each.
M.SHAPES = { "●", "■", "▲", "◆", "★", "♥", "♠", "♣" }
local COLOURS = {
  "DiagnosticError",
  "DiagnosticWarn",
  "DiagnosticOk",
  "DiagnosticInfo",
  "DiagnosticHint",
  "Statement",
  "Special",
  "Constant",
}

local index_of = {}
for i, emoji in ipairs(M.SET) do
  index_of[emoji] = i
end

local function symbols()
  return require("floatterm.settings").get "tab_icons" == "symbols"
end

local function tabs()
  local floatterm = package.loaded["floatterm"]
  return floatterm and floatterm.tabs() or {}
end

-- What has to differ between two tabs: the emoji, or with symbols, the shape and
-- colour it gives.
local function key(emoji)
  if symbols() then
    local i = index_of[emoji]
    return i and (i - 1) % (#M.SHAPES * #COLOURS) or emoji
  end
  return emoji
end

-- The emoji (or symbols) other tabs are showing, as a set of keys.
function M.in_use(except)
  local used = {}
  for _, record in ipairs(tabs()) do
    if record ~= except and record.emoji then
      used[key(record.emoji)] = true
    end
  end
  return used
end

-- A random emoji from SET that no other tab's looks like, or any from SET once
-- they're all taken.
function M.random(except)
  local used = M.in_use(except)
  local free = vim.tbl_filter(function(emoji)
    return not used[key(emoji)]
  end, M.SET)
  local from = #free > 0 and free or M.SET
  return from[math.random(#from)]
end

-- What the tab bar shows for a tab: { text, hl } two columns wide, its emoji or with
-- symbols its shape in its colour. nil for a group heading.
function M.icon(record)
  if record.kind == "group" then
    return nil
  end
  local i = index_of[record.emoji or ""]
  if symbols() and i then
    local shape = M.SHAPES[(i - 1) % #M.SHAPES + 1]
    local colour = math.floor((i - 1) / #M.SHAPES) % #COLOURS + 1
    return { shape .. " ", "FloatTermIcon" .. colour }
  end
  return { record.emoji or "  ", nil }
end

-- The icon's text alone. nil for a group heading.
function M.glyph(record)
  local icon = M.icon(record)
  return icon and icon[1]:gsub(" $", "") or nil
end

-- Gives every tab that's missing an emoji, has one no longer in SET, or looks like a
-- tab above it, a new one.
function M.ensure_all()
  local above = {}
  for _, record in ipairs(tabs()) do
    if record.kind ~= "group" and record.buf then
      local emoji = record.emoji
      if not emoji or not index_of[emoji] or above[key(emoji)] then
        emoji = M.random(record)
        require("floatterm").update(record.buf, { emoji = emoji })
      end
      above[key(emoji)] = true
    end
  end
end

function M.set_highlights()
  for i, group in ipairs(COLOURS) do
    local from = api.nvim_get_hl(0, { name = group, link = false })
    api.nvim_set_hl(0, "FloatTermIcon" .. i, { fg = from.fg, bold = true, default = true })
  end
end

-- Fields so tests can stand in for them.
M.is_linux = function()
  return vim.fn.has "linux" == 1
end
-- Calls back with the font families fontconfig knows (one per line), or nil when it
-- can't say.
M.list_fonts = function(callback)
  local ok = pcall(vim.system, { "fc-list", ":", "family" }, { text = true }, function(result)
    callback(result.code == 0 and result.stdout or nil)
  end)
  if not ok then
    callback(nil)
  end
end

-- On Linux, with emoji showing, says so when no colour emoji font is installed.
function M.check_font()
  if not M.is_linux() or symbols() then
    return
  end
  M.list_fonts(function(families)
    if families and not families:lower():find("color emoji", 1, true) then
      vim.schedule(function()
        vim.notify(
          "floatterm: no colour emoji font, so tab emoji may show as outlines or blanks. "
            .. "Run ~/.config/nvim/bin/fix-emoji-font, or set Tab icons to symbols in :FloatTermSettings",
          vim.log.levels.WARN
        )
      end)
    end
  end)
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true
  local group = api.nvim_create_augroup("floatterm_emoji", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FloatTermTabsChanged", "FloatTermTabChanged", "FloatTermSettingsChanged" },
    callback = function()
      vim.schedule(M.ensure_all)
    end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.set_highlights })
  M.set_highlights()
  M.ensure_all()
  M.check_font()
end

return M
