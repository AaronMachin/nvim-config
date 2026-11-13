-- An emoji for every tab, so tabs are easier to tell apart in the tab bar.
--
-- A shell tab gets a random one from SET when it first shows, one no other tab is
-- using while there are any left. A Claude tab shows ✳ until it has an emoji picked
-- for it as a Claude tab. A shell tab that Claude starts in goes back to ✳ until then,
-- and a Claude tab that becomes a shell again keeps its emoji, as it's still the same
-- piece of work. Group headings get none.
--
-- The emoji is kept on the tab's record (emoji, and emoji_for: "shell" or "claude"),
-- and lua/floatterm/restore saves it with the tab, so it's the same when tabs reopen.

local M = {}

-- Easy to tell apart at a glance, and each one character two columns wide in nvim
-- (no variation selectors), so the bar's columns line up.
M.SET = {
  "🦊", "🐙", "🌵", "🍋", "🐝", "🦉", "🍄", "🌻", "🐢", "🦀", "🍉", "🎈", "🪁", "🧩",
  "🎲", "🚀", "⚓", "🌙", "🔥", "🌊", "🍀", "🐳", "🦋", "🍒", "🥑", "🎯", "🧲", "🔔",
  "🪐", "🌈", "🐌", "🦔", "🍩", "🧊", "🪴", "🎸", "🛶", "🏮", "🧸", "🦜", "⭐", "⚡",
}

-- What a Claude tab shows until it has its own emoji.
M.PENDING = "✳"

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

-- What the tab bar shows for a tab: its emoji, ✳ for a Claude tab still waiting for
-- one, nil for a group heading.
function M.glyph(record)
  if record.kind == "group" then
    return nil
  end
  if record.kind == "claude" and record.emoji_for ~= "claude" then
    return M.PENDING
  end
  return record.emoji or M.PENDING
end

-- Gives a tab the emoji it's missing.
function M.ensure(record)
  if record.kind == "group" or not record.buf then
    return
  end
  if record.kind ~= "claude" and not record.emoji then
    require("floatterm").update(record.buf, { emoji = M.random(record), emoji_for = "shell" })
  end
end

function M.ensure_all()
  for _, record in ipairs(tabs()) do
    M.ensure(record)
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
