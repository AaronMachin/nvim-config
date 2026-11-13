-- An emoji for every tab, so tabs are easier to tell apart in the tab bar.
--
-- A shell tab gets a random one from SET when it first shows, one no other tab is
-- using while there are any left. A Claude tab shows ✳ until Claude has set a title
-- saying what it's working on; then Haiku picks one from that title and the prompt,
-- in the background (a random one when claude isn't installed or the pick fails).
-- A shell tab that Claude starts in goes back to ✳ until then,
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

-- The reply if it's one emoji: one character two columns wide, once any variation
-- selector is taken off. Otherwise nil.
function M.parse(reply)
  local text = vim.trim(reply or ""):gsub("\239\184\143", "")
  if vim.fn.strchars(text) == 1 and vim.fn.strdisplaywidth(text) == 2 and not text:match "^[%w%p]$" then
    return text
  end
  return nil
end

-- Whether Haiku picks Claude tabs' emoji. Off (vim.g.floatterm_emoji_picker = false),
-- Claude tabs keep ✳; the tests turn it off so nothing reaches the real claude.
M.picker = vim.g.floatterm_emoji_picker ~= false

-- How long the picker may take before the tab gets a random emoji instead.
M.TIMEOUT = 30000

-- Claude tabs being picked for, by buffer.
local picking = {}

local function prompt(record, summary)
  local used = vim.tbl_keys(M.in_use(record))
  table.sort(used)
  local first = type(record.last_prompt) == "string" and record.last_prompt:sub(1, 400) or ""
  return table.concat({
    "Pick one emoji for a terminal tab, so its owner can spot it among their other tabs.",
    "The Claude Code session in the tab is working on: " .. summary,
    first ~= "" and ("Its prompt began: " .. first) or "",
    #used > 0 and ("Other tabs already use these, so pick a different one: " .. table.concat(used, " ")) or "",
    "Reply with the emoji only: a single emoji character, no variation selector, no other text.",
  }, "\n")
end

-- Asks Haiku for a Claude tab's emoji, in the background. Without `claude` on the PATH,
-- or when it fails or its reply isn't one emoji, the tab gets a random one.
local function pick(record, summary)
  local buf = record.buf
  picking[buf] = true
  local function done(chosen)
    picking[buf] = nil
    local now = require("floatterm").record(buf)
    if now and now.kind == "claude" and now.emoji_for ~= "claude" then
      require("floatterm").update(buf, { emoji = chosen or M.random(now), emoji_for = "claude" })
    end
  end
  if vim.fn.executable "claude" ~= 1 then
    done(nil)
    return
  end
  -- Without the user's own settings (--setting-sources ""), so their hooks and plugins
  -- don't run for this, and from the cache folder so no project's CLAUDE.md is read.
  local ok = pcall(vim.system, {
    "claude",
    "-p",
    "--model",
    "haiku",
    "--setting-sources",
    "",
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
    prompt(record, summary),
  }, { text = true, timeout = M.TIMEOUT, cwd = vim.fn.stdpath "cache", env = { FLOATTERM_TAB_ID = "" } }, function(result)
    vim.schedule(function()
      done(result.code == 0 and M.parse(result.stdout) or nil)
    end)
  end)
  if not ok then
    done(nil)
  end
end

-- Gives a tab the emoji it's missing. A Claude tab gets one once Claude has set a
-- title saying what it's working on.
function M.ensure(record)
  if record.kind == "group" or not record.buf then
    return
  end
  if record.kind ~= "claude" then
    if not record.emoji then
      require("floatterm").update(record.buf, { emoji = M.random(record), emoji_for = "shell" })
    end
    return
  end
  if not M.picker or record.emoji_for == "claude" or picking[record.buf] then
    return
  end
  local summary = require("floatterm.tabbar").title_summary(record)
  if summary then
    pick(record, summary)
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
