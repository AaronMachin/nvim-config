-- "Look at this": a Claude tab lit up purple in the tab bar when Claude has found
-- something for you, with what it is on the tab's second line in place of its state.
--
-- Claude flags its tab itself with bin/floatterm-look "<one line>" (the floatterm
-- skill and the note the SessionStart hook adds tell it when). As a safety net, the
-- small Claude that rewrites the tab's summary after each turn (lua/floatterm/
-- claude_notes) also says whether the turn ended with something for you, and flags
-- the tab when Claude didn't that turn.
--
-- Going into the tab clears it: the message shows over the top of the terminal for
-- ARRIVE_MS as you arrive, then goes. A tab you're already looking at isn't lit up,
-- only shows the message.
--
-- On the tab's record: look (the message), look_flagged (Claude flagged it itself
-- this turn; cleared when you send a prompt), look_seen (the safety net's last
-- message, so the same one isn't flagged again after you've cleared it).

local M = {}

local api = vim.api

M.ARRIVE_MS = 6000
local MAX = 200

local function ft()
  return require "floatterm"
end

local function find_tab(tab_id)
  for _, record in ipairs(ft().tabs()) do
    if tostring(record.id) == tostring(tab_id) and record.kind ~= "group" then
      return record
    end
  end
end

-- Whether you're looking at the tab now: the float open and showing it.
local function looking_at(record)
  local win = ft().window()
  return win ~= nil and api.nvim_win_get_buf(win) == record.buf
end

local note_win, note_timer = nil, nil

local function close_note()
  if note_timer then
    note_timer:stop()
    note_timer:close()
    note_timer = nil
  end
  if note_win and api.nvim_win_is_valid(note_win) then
    api.nvim_win_close(note_win, true)
  end
  note_win = nil
end

-- The message over the top right of the terminal for ARRIVE_MS, without taking focus.
local function show_note(message)
  close_note()
  local win = ft().window()
  if not win then
    return
  end
  local width = math.max(10, math.min(70, api.nvim_win_get_width(win) - 6))
  local lines = {}
  for _, line in ipairs(vim.split(vim.fn.trim(message), "\n")) do
    while vim.fn.strdisplaywidth(line) > width - 2 do
      local cut = vim.fn.strcharpart(line, 0, width - 2)
      local space = cut:match ".*() "
      if space and space > 1 then
        cut = cut:sub(1, space - 1)
      end
      table.insert(lines, " " .. cut)
      line = vim.trim(line:sub(#cut + 1))
    end
    table.insert(lines, " " .. line)
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line) + 1)
  end
  note_win = api.nvim_open_win(buf, false, {
    relative = "win",
    win = win,
    row = 0,
    col = math.max(0, api.nvim_win_get_width(win) - widest - 2),
    width = widest,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " Claude found ",
    focusable = false,
    noautocmd = true,
    zindex = 70,
  })
  vim.wo[note_win].winhighlight = "Normal:FloatTermLook,FloatBorder:FloatTermLookBorder,FloatTitle:FloatTermLookBorder"
  note_timer = vim.uv.new_timer()
  note_timer:start(M.ARRIVE_MS, 0, vim.schedule_wrap(close_note))
end

-- The note's window, for tests.
function M.note_window()
  return note_win and api.nvim_win_is_valid(note_win) and note_win or nil
end

local function clean(message)
  message = vim.trim(type(message) == "string" and message or "")
  message = message:gsub("%s*\n%s*", " ")
  if vim.fn.strchars(message) > MAX then
    message = vim.fn.strcharpart(message, 0, MAX - 1) .. "…"
  end
  return message
end

-- Lights up `record` with `message`; from Claude itself unless `from` is "net". Returns
-- "flagged", "shown" (you're looking at it, so only the note showed) or "".
function M.flag_record(record, message, from)
  message = clean(message)
  if not record or message == "" then
    return ""
  end
  local fields = { look = message }
  if from ~= "net" then
    fields.look_flagged = true
  end
  if looking_at(record) then
    show_note(message)
    if fields.look_flagged then
      ft().update(record.buf, { look_flagged = true })
    end
    return "shown"
  end
  ft().update(record.buf, fields)
  return "flagged"
end

-- For bin/floatterm-look: flags the tab `tab_id`.
function M.flag(tab_id, message)
  return M.flag_record(find_tab(tab_id), message)
end

-- The safety net, after the summary run for `record`: `message` is what the small
-- Claude said needs you ("" for nothing). Only when Claude didn't flag it this turn,
-- and not the same message again.
function M.from_summary(record, message)
  message = clean(message)
  if not record or message == "" or record.look_flagged or record.look or message == record.look_seen then
    return
  end
  ft().update(record.buf, { look_seen = message })
  M.flag_record(record, message, "net")
end

-- Clears the tab you've gone into, showing its message as you arrive.
local function arrived()
  local buf = ft().current_buf()
  local record = buf and ft().record(buf)
  if record and record.look and looking_at(record) then
    local message = record.look
    ft().update(record.buf, { look = vim.NIL })
    show_note(message)
  end
end

function M.set_highlights()
  local ok, c = pcall(function()
    return require("base46").get_theme_tb "base_30"
  end)
  local purple, ink
  if ok and type(c) == "table" and c.purple then
    purple, ink = c.purple, c.black
  else
    purple = api.nvim_get_hl(0, { name = "Statement", link = false }).fg
    ink = api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  end
  api.nvim_set_hl(0, "FloatTermLook", { bg = purple, fg = ink, bold = true, default = true })
  api.nvim_set_hl(0, "FloatTermLookBorder", { fg = purple, bold = true, default = true })
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true
  local group = api.nvim_create_augroup("floatterm_look", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FloatTermTabChanged", "FloatTermTabsChanged", "FloatTermLayoutChanged" },
    callback = function()
      vim.schedule(arrived)
    end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.set_highlights })
  M.set_highlights()
end

return M
