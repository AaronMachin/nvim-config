-- An emoji for every tab, so tabs are easier to tell apart in the tab bar.
--
-- Each tab gets a random one from SET when it first shows, Claude and shell alike, and
-- no two tabs share one: that's what makes them worth having. If two tabs end up with
-- the same one (restored from before this rule, say), the one further down the bar
-- gets a new one. Only with more tabs than SET has emoji can two match. Group
-- headings get none.
--
-- The emoji is kept on the tab's record (emoji), and lua/floatterm/restore saves it
-- with the tab, so it's the same when tabs reopen.

local M = {}

-- Easy to tell apart at a glance, and each one character two columns wide (no
-- variation selectors, none that terminals show narrow), so the bar's columns line up.
M.SET = {
  "🦊", "🐙", "🌵", "🍋", "🐝", "🦉", "🍄", "🌻", "🐢", "🦀", "🍉", "🎈", "🪁", "🧩",
  "🎲", "🚀", "🌙", "🔥", "🌊", "🍀", "🐳", "🦋", "🍒", "🥑", "🎯", "🧲", "🔔", "🪐",
  "🌈", "🐌", "🦔", "🍩", "🧊", "🪴", "🎸", "🛶", "🏮", "🧸", "🦜", "⭐", "⚡", "🦄",
  "🦢", "🐧", "🐸", "🐼", "🐨", "🦁", "🐯", "🦒", "🦓", "🐘", "🦩", "🦚", "🐞", "🦞",
  "🐠", "🍓", "🍍", "🥝", "🥕", "🌽", "🍕", "🧁", "🍪", "🥨", "🧀", "🍇", "🍑", "🎺",
  "🎻", "🥁", "🎨", "🎭", "🪀", "🛼", "🛸", "🚂", "⛵", "🏰", "🗿", "💎", "🔮", "🧭",
  "🪄", "🏆", "🌋", "🌷", "🌲", "🍁", "🌀", "🧿", "🪸", "🦦", "🦥", "🐉",
}

local function tabs()
  local floatterm = package.loaded["floatterm"]
  return floatterm and floatterm.tabs() or {}
end

-- The emoji other tabs are showing, as a set.
function M.in_use(except)
  local used = {}
  for _, record in ipairs(tabs()) do
    if record ~= except and record.emoji then
      used[record.emoji] = true
    end
  end
  return used
end

-- A random emoji from SET that no other tab has, or any from SET once they're all
-- taken.
function M.random(except)
  local used = M.in_use(except)
  local free = vim.tbl_filter(function(emoji)
    return not used[emoji]
  end, M.SET)
  local from = #free > 0 and free or M.SET
  return from[math.random(#from)]
end

-- What the tab bar shows for a tab: its emoji, nil for a group heading.
function M.glyph(record)
  if record.kind == "group" then
    return nil
  end
  return record.emoji or "  "
end

-- Gives every tab that's missing an emoji, or shares one with a tab above it, a new
-- one.
function M.ensure_all()
  local above = {}
  for _, record in ipairs(tabs()) do
    if record.kind ~= "group" and record.buf then
      local emoji = record.emoji
      if not emoji or above[emoji] then
        emoji = M.random(record)
        require("floatterm").update(record.buf, { emoji = emoji })
      end
      above[emoji] = true
    end
  end
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("floatterm_emoji", { clear = true }),
    pattern = { "FloatTermTabsChanged", "FloatTermTabChanged" },
    callback = function()
      vim.schedule(M.ensure_all)
    end,
  })
  M.ensure_all()
end

return M
