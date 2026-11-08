-- The floating terminal's tab bar, and what it knows about each tab.
--
-- The bar sits inside the float, down its left side or along its top (the tabbar
-- setting), in the box lua/floatterm keeps for it. It's drawn in its own window that
-- can't be focused until Ctrl+Shift+b moves the cursor into it, and it closes with
-- the float.
--
-- Tabs under a parent (lua/floatterm/groups) are drawn under it: down the left with
-- ├ and └, along the top right after it with └. A parent with its children folded
-- away (za) shows how many with ▸. A group heading is one line, ▾ and its name.
--
-- A Claude tab shows its state first, then what it's working on, then its folder;
-- when space runs out the folder goes first, then the summary, never the state. A
-- shell tab shows its folder and what's running in it.
--
-- While tabs exist, a timer (once a second) copies each tab's terminal title into its
-- record. While the bar is drawn or a Claude tab exists, it also works out each shell
-- tab's foreground command with `ps`, so the bar and anything else reading the records
-- (sessions) stay current.

local M = {}

local api = vim.api
local settings = require "floatterm.settings"

local ns = api.nvim_create_namespace "floatterm_tabbar"
local INTERVAL = 1000
local SEPARATOR = " │ "

local bar_win = nil
local bar_buf = nil
-- The rows drawn (lua/floatterm/groups M.rows: the tabs not folded away), and per
-- row, where it was drawn: { buf, first, last } (0-based lines) and,
-- along the top, { start_col, end_col } as byte columns and { start_cell, end_cell }
-- as screen columns.
local entries = {}
local rows_drawn = {}
-- The row the cursor is on while it's in the bar.
local selected = nil
-- While a parent is being picked: per record, the number to type for it (show_numbers).
local numbers = nil
-- The popup beside the selected tab saying what the keys do (defined below redraw).
local update_hint, close_hint
local timer = nil
local busy = false
-- How many times `ps` has been started. For tests and debugging.
M.ps_runs = 0
-- Per tab buffer: idle when the shell is waiting at its prompt, ran once anything has
-- run in it since this nvim opened it (until then a restored last_command shows).
local idle = {}
local ran = {}

M.STATES = {
  needs_you = { glyph = "●", word = "needs you", hl = "FloatTermNeedsYou" },
  working = { glyph = "◌", word = "working", hl = "FloatTermWorking" },
  done = { glyph = "✓", word = "done", hl = "FloatTermDone" },
}
-- A Claude tab nothing has reported a status for yet.
local NEW = { glyph = "✳", word = "new", hl = "FloatTermDone" }

local SHELLS = { sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true }

local function set_highlights()
  local warn = api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  api.nvim_set_hl(0, "FloatTermNeedsYou", { fg = warn.fg, bold = true })
  api.nvim_set_hl(0, "FloatTermWorking", { link = "Comment", default = true })
  api.nvim_set_hl(0, "FloatTermDone", { link = "LineNr", default = true })
  api.nvim_set_hl(0, "FloatTermCurrent", { bold = true, default = true })
  api.nvim_set_hl(0, "FloatTermSelected", { link = "Visual", default = true })
  api.nvim_set_hl(0, "FloatTermGroup", { link = "Title", default = true })
  api.nvim_set_hl(0, "FloatTermTree", { link = "FloatBorder", default = true })
  api.nvim_set_hl(0, "FloatTermNumber", { link = "IncSearch", default = true })
  api.nvim_set_hl(0, "FloatTermHintKey", { link = "Function", default = true })
  api.nvim_set_hl(0, "FloatTermHintBorder", { link = "Function", default = true })
end
set_highlights()

-- The state a Claude tab shows: { glyph, word, hl }.
function M.state(record)
  return M.STATES[record.status] or NEW
end

local function elapsed(since)
  local seconds = math.max(0, os.time() - since)
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local function state_text(record)
  local state = M.state(record)
  local text = state.glyph .. " " .. state.word
  if record.status and record.status_since then
    text = text .. " · " .. elapsed(record.status_since)
  end
  return text, state.hl
end

-- What a Claude tab is working on: the title Claude set, without its spinner, else
-- the first line of the last prompt.
function M.summary(record)
  local title = record.title
  if type(title) == "string" and not title:match "^term://" and title ~= record.shell_title then
    title = vim.trim((title:gsub("^[^%w%(%[\"']+", "")))
    -- Claude's own name is the title before it has a task.
    if title ~= "" and title ~= "Claude Code" then
      return title
    end
  end
  if type(record.last_prompt) == "string" and record.last_prompt ~= "" then
    return vim.trim(vim.split(record.last_prompt, "\n")[1])
  end
  return nil
end

local function shell_name()
  return vim.fs.basename(vim.o.shell)
end

-- True when a shell tab has something other than its shell running.
function M.is_running(record)
  return record.kind ~= "claude" and record.command ~= nil and not idle[record.buf]
end

-- A shell tab's command line and its highlight (nil for normal text).
local function shell_command(record)
  if M.is_running(record) then
    return record.command, nil
  end
  if record.last_command and not ran[record.buf] then
    return record.last_command, "FloatTermWorking"
  end
  return record.command or shell_name(), "FloatTermWorking"
end

-- Commands as `ps` gives them, made readable: the program's name without its path, and
-- for a shell running a script (vendor/bin/sail is one), the script's name instead.
local function tidy(args)
  local words = vim.split(vim.trim(args), "%s+")
  words[1] = (vim.fs.basename(words[1]):gsub("^%-", ""))
  if SHELLS[words[1]] and words[2] and not words[2]:match "^%-" then
    table.remove(words, 1)
    words[1] = vim.fs.basename(words[1])
  end
  return table.concat(words, " ")
end

-- Chunks are { text, hl } pairs that make up one line.
local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

-- Cuts a line of chunks to `width` screen columns, ending it with … when cut.
local function truncate(chunks, width)
  if chunks_width(chunks) <= width then
    return chunks
  end
  local out, used = {}, 0
  for _, chunk in ipairs(chunks) do
    local text = chunk[1]
    local room = width - 1 - used
    if room <= 0 then
      break
    end
    if vim.fn.strdisplaywidth(text) > room then
      local chars = vim.fn.strchars(text)
      while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, chars)) > room do
        chars = chars - 1
      end
      table.insert(out, { vim.fn.strcharpart(text, 0, chars), chunk[2] })
      break
    end
    table.insert(out, chunk)
    used = used + vim.fn.strdisplaywidth(text)
  end
  table.insert(out, { "…", nil })
  return out
end

-- Down the left side: a few lines per tab. Levels drop, in turn, the blank line
-- between tabs, a Claude tab's folder, then its summary and a shell's command.
local function vertical_tab(record, level, row)
  local lines = {}
  if record.kind == "group" then
    local name = require("floatterm").name(record)
    lines = { { { (row.folded and "▸ " or "▾ ") .. name, "FloatTermGroup" } } }
  elseif record.kind == "claude" then
    local text, hl = state_text(record)
    table.insert(lines, { { text, hl } })
    local summary = M.summary(record)
    if level < 3 and summary then
      table.insert(lines, { { summary, nil } })
    end
    if level < 2 then
      table.insert(lines, { { "✳ " .. require("floatterm").name(record), "FloatTermWorking" } })
    end
  else
    table.insert(lines, { { "$ " .. require("floatterm").name(record), nil } })
    if level < 3 then
      local command, hl = shell_command(record)
      table.insert(lines, { { command, hl } })
    end
  end
  -- Notes on (lua/floatterm/notes), after the state or folder.
  if record.notes_on then
    table.insert(lines[1], { " ✎", nil })
  end
  if row.folded and record.kind ~= "group" then
    table.insert(lines[1], { " ▸" .. row.folded, "FloatTermWorking" })
  elseif row.folded then
    table.insert(lines[1], { " · " .. row.folded, "FloatTermWorking" })
  end
  return lines
end

-- The tree's lines before a row's first line and before the rest.
local function tree_prefix(row)
  if row.depth == 0 then
    return "", ""
  end
  local rails = ""
  for level = 1, row.depth - 1 do
    rails = rails .. (row.rails[level] and "│ " or "  ")
  end
  return rails .. (row.last and "└ " or "├ "), rails .. (row.last and "  " or "│ ")
end

-- The number to type for a tab while a parent is being picked, padded so the tabs
-- still line up; blank for a tab that can't be picked.
local function number_chunk(record)
  local widest = 0
  for _, n in pairs(numbers) do
    widest = math.max(widest, #tostring(n))
  end
  local n = numbers[record]
  if not n then
    return { string.rep(" ", widest + 1), nil }
  end
  return { string.rep(" ", widest - #tostring(n)) .. n, "FloatTermNumber" }
end

local function render_vertical(rows, current, height, width)
  local level, all
  local roots = 0
  for _, row in ipairs(rows) do
    roots = roots + (row.depth == 0 and 1 or 0)
  end
  for try = 0, 3 do
    level, all = try, {}
    for _, row in ipairs(rows) do
      table.insert(all, vertical_tab(row.record, level, row))
    end
    -- Blank lines go between the trees, not inside one.
    local count = (level == 0) and (roots - 1) or 0
    for _, lines in ipairs(all) do
      count = count + #lines
    end
    if count <= height then
      break
    end
  end

  local out, spans = {}, {}
  for i, lines in ipairs(all) do
    if level == 0 and i > 1 and rows[i].depth == 0 then
      table.insert(out, {})
    end
    local first = #out
    local head, rest = tree_prefix(rows[i])
    for n, line in ipairs(lines) do
      local marker = (n == 1 and i == current) and "▶ " or "  "
      local chunks = { { marker, nil } }
      if numbers then
        local number = n == 1 and number_chunk(rows[i].record) or { string.rep(" ", #number_chunk(rows[i].record)[1]) }
        table.insert(chunks, number)
        table.insert(chunks, { " ", nil })
      end
      if head ~= "" then
        table.insert(chunks, { n == 1 and head or rest, "FloatTermTree" })
      end
      table.insert(out, truncate(vim.list_extend(chunks, line), width))
    end
    spans[i] = { first = first, last = #out - 1 }
  end
  return out, spans
end

-- Along the top: one segment per tab on one line.
local function horizontal_tab(record, level, cap, row)
  local parts = {}
  if record.kind == "group" then
    table.insert(parts, { (row.folded and "▸ " or "▾ ") .. require("floatterm").name(record), "FloatTermGroup" })
  elseif record.kind == "claude" then
    local text, hl = state_text(record)
    table.insert(parts, { text, hl })
    local summary = M.summary(record)
    if level < 3 and summary then
      if cap and vim.fn.strchars(summary) > cap then
        summary = vim.fn.strcharpart(summary, 0, cap - 1) .. "…"
      end
      table.insert(parts, { summary, nil })
    end
    if level < 1 then
      table.insert(parts, { require("floatterm").name(record), "FloatTermWorking" })
    end
  else
    table.insert(parts, { "$ " .. require("floatterm").name(record), nil })
    if level < 3 then
      local command, hl = shell_command(record)
      if cap and vim.fn.strchars(command) > cap then
        command = vim.fn.strcharpart(command, 0, cap - 1) .. "…"
      end
      table.insert(parts, { command, hl })
    end
  end

  local chunks = {}
  for n, part in ipairs(parts) do
    if n > 1 then
      table.insert(chunks, { " · ", "FloatTermWorking" })
    end
    table.insert(chunks, part)
  end
  if record.notes_on then
    table.insert(chunks, 2, { " ✎", nil })
  end
  if row.folded then
    table.insert(chunks, 2, { (record.kind == "group" and " · " or " ▸") .. row.folded, "FloatTermWorking" })
  end
  -- A child follows its parent, marked as one.
  if row.depth > 0 then
    table.insert(chunks, 1, { "└ ", "FloatTermTree" })
  end
  return chunks
end

-- `shown` is the tab that must stay in view: the cursor's when it's in the bar.
local function render_horizontal(rows, current, width, shown)
  -- Level 0 is everything; 1 drops Claude folders; 2 shortens summaries and commands
  -- step by step; 3 drops them.
  local tries = { { 0 }, { 1 }, { 2, 40 }, { 2, 28 }, { 2, 18 }, { 2, 10 }, { 3 } }
  local segments
  for _, try in ipairs(tries) do
    segments = {}
    local total = 0
    for i, row in ipairs(rows) do
      local chunks = horizontal_tab(row.record, try[1], try[2], row)
      table.insert(chunks, 1, { i == current and "▶ " or "", nil })
      if numbers and numbers[row.record] then
        table.insert(chunks, 2, { tostring(numbers[row.record]), "FloatTermNumber" })
        table.insert(chunks, 3, { " ", nil })
      end
      segments[i] = chunks
      total = total + chunks_width(chunks) + (i > 1 and vim.fn.strdisplaywidth(SEPARATOR) or 0)
    end
    if total <= width then
      break
    end
  end

  -- Still too wide: start further along so the tab in `shown` is in view, with ‹ saying
  -- there are tabs before it.
  local sep = vim.fn.strdisplaywidth(SEPARATOR)
  local first = 1
  local function width_to_current()
    local total = first > 1 and 2 or 0
    for i = first, shown do
      total = total + chunks_width(segments[i]) + (i > first and sep or 0)
    end
    return total
  end
  while first < shown and width_to_current() > width do
    first = first + 1
  end

  local line, spans, bytes, cells = {}, {}, 0, 0
  if first > 1 then
    table.insert(line, { "‹ ", "FloatTermWorking" })
    bytes, cells = #"‹ ", 2
  end
  for i, chunks in ipairs(segments) do
    if i < first then
      spans[i] = { first = 0, last = 0, start_col = -1, end_col = -1, start_cell = -1, end_cell = -1 }
      goto continue
    end
    if i > first then
      table.insert(line, { SEPARATOR, "FloatBorder" })
      bytes, cells = bytes + #SEPARATOR, cells + vim.fn.strdisplaywidth(SEPARATOR)
    end
    local span = { first = 0, last = 0, start_col = bytes, start_cell = cells }
    for _, chunk in ipairs(chunks) do
      table.insert(line, chunk)
      bytes, cells = bytes + #chunk[1], cells + vim.fn.strdisplaywidth(chunk[1])
    end
    span.end_col, span.end_cell = bytes, cells
    spans[i] = span
    ::continue::
  end
  return { truncate(line, width) }, spans
end

local function close()
  if bar_win and api.nvim_win_is_valid(bar_win) then
    api.nvim_win_close(bar_win, true)
  end
  bar_win = nil
  selected = nil
  close_hint()
end

local function is_open()
  return bar_win ~= nil and api.nvim_win_is_valid(bar_win)
end

local function is_horizontal()
  return settings.get "tabbar" == "top"
end

local function place_cursor()
  local span = selected and entries[selected]
  if not (span and is_open()) then
    return
  end
  local col = is_horizontal() and span.start_col or 0
  pcall(api.nvim_win_set_cursor, bar_win, { span.first + 1, col })
end

local function window_config(box)
  if is_horizontal() then
    return { relative = "editor", row = box.row, col = box.col, width = box.width, height = 1, border = "none" }
  end
  return {
    relative = "editor",
    row = box.row,
    col = box.col,
    width = box.width - 2,
    height = box.height - 2,
    border = "rounded",
  }
end

-- Draws the bar now, or closes it when the float is hidden, the bar is off or there's
-- no room for it.
function M.redraw()
  local floatterm = package.loaded["floatterm"]
  if not floatterm then
    return
  end
  local layout = floatterm.layout()
  local tabs = floatterm.tabs()
  local box = layout.tabbar
  if not layout.open or not box or #tabs == 0 or box.width < 4 or (not is_horizontal() and box.height < 3) then
    close()
    return
  end
  -- A float only shows on the tab page it was opened on, so the bar belongs there too.
  -- A redraw scheduled before a tab-page switch leaves it alone; the float's own tab
  -- page redraws it when it's entered again.
  local float_tab = api.nvim_win_get_tabpage(floatterm.window())
  if is_open() and api.nvim_win_get_tabpage(bar_win) ~= float_tab then
    close()
  end
  if float_tab ~= api.nvim_get_current_tabpage() then
    return
  end

  local groups = require "floatterm.groups"
  rows_drawn = groups.rows()
  -- A tab folded away marks its parent's row.
  local current = groups.row_of(rows_drawn, floatterm.record(floatterm.current_buf() or -1)) or 1

  local config = window_config(box)
  local rows
  if is_horizontal() then
    rows, entries = render_horizontal(rows_drawn, current, config.width, math.min(selected or current, #rows_drawn))
  else
    rows, entries = render_vertical(rows_drawn, current, config.height, config.width)
  end
  if selected then
    selected = math.min(selected, #rows_drawn)
  end

  if not (bar_buf and api.nvim_buf_is_valid(bar_buf)) then
    bar_buf = api.nvim_create_buf(false, true)
    vim.bo[bar_buf].filetype = "floattermbar"
    M.map_bar_keys(bar_buf)
  end

  local lines = {}
  for n, chunks in ipairs(rows) do
    local text = ""
    for _, chunk in ipairs(chunks) do
      text = text .. chunk[1]
    end
    lines[n] = text
  end
  vim.bo[bar_buf].modifiable = true
  api.nvim_buf_set_lines(bar_buf, 0, -1, false, lines)
  vim.bo[bar_buf].modifiable = false

  api.nvim_buf_clear_namespace(bar_buf, ns, 0, -1)
  for n, chunks in ipairs(rows) do
    local col = 0
    for _, chunk in ipairs(chunks) do
      if chunk[2] then
        api.nvim_buf_set_extmark(bar_buf, ns, n - 1, col, {
          end_col = col + #chunk[1],
          hl_group = chunk[2],
          priority = 200,
        })
      end
      col = col + #chunk[1]
    end
  end
  local function mark(span, hl)
    local line_end = #lines[span.last + 1]
    -- A segment cut off the end of a full top bar has nothing left to mark.
    if span.start_col and (span.start_col < 0 or span.start_col >= line_end) then
      return
    end
    api.nvim_buf_set_extmark(bar_buf, ns, span.first, span.start_col or 0, {
      end_row = span.end_col and span.last or span.last + 1,
      end_col = span.end_col and math.min(span.end_col, line_end) or 0,
      hl_group = hl,
      hl_eol = not span.end_col,
      priority = 100,
    })
  end
  if entries[current] then
    mark(entries[current], "FloatTermCurrent")
  end
  if selected and entries[selected] then
    mark(entries[selected], "FloatTermSelected")
  end

  if is_open() then
    api.nvim_win_set_config(bar_win, config)
  else
    config.style = "minimal"
    config.focusable = false
    config.noautocmd = true
    bar_win = api.nvim_open_win(bar_buf, false, config)
    vim.wo[bar_win].wrap = false
    vim.wo[bar_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  end

  update_hint()
  if selected then
    place_cursor()
  elseif not is_horizontal() and entries[current] then
    -- Keeps the current tab in view when the tabs don't all fit.
    api.nvim_win_call(bar_win, function()
      local top = vim.fn.line "w0"
      local bottom = vim.fn.line "w$"
      if entries[current].first + 1 < top or entries[current].last + 1 > bottom then
        vim.fn.winrestview { topline = math.max(1, entries[current].last + 2 - config.height) }
      end
    end)
  end
end

-- The key hints ----------------------------------------------------------------

local hint_win, hint_buf = nil, nil
local hint_ns = api.nvim_create_namespace "floatterm_tabbar_hint"

close_hint = function()
  if hint_win and api.nvim_win_is_valid(hint_win) then
    api.nvim_win_close(hint_win, true)
  end
  hint_win = nil
end

-- The widest the popup gets, so a long command doesn't stretch it across the screen.
local HINT_WIDTH = 60
-- The tab whose full command the popup is showing (`c`), until the selection moves.
local full_command_for = nil

-- `text` in lines of at most `width` columns.
local function wrap(text, width)
  local lines = {}
  while vim.fn.strdisplaywidth(text) > width do
    local chars = width
    while chars > 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, chars)) > width do
      chars = chars - 1
    end
    table.insert(lines, vim.fn.strcharpart(text, 0, chars))
    text = vim.fn.strcharpart(text, chars)
  end
  table.insert(lines, text)
  return lines
end

-- What the popup says for `record`: a heading, what kind of tab it is, then the keys
-- that do something to it. Each line is a list of { text, hl } chunks. `width` is the
-- room for text: longer lines are cut with … where the popup is drawn, apart from a
-- running command shown in full with `c`, which wraps.
local function hint_rows(record, width)
  local floatterm = require "floatterm"
  local groups = require "floatterm.groups"
  local rows = {}
  local under = #groups.children(record)
  local kind
  -- A command too long for the popup, and whether it's showing in full.
  local long_command, full = false, false
  if record.kind == "group" then
    table.insert(rows, { { "▾ " .. floatterm.name(record), "FloatTermGroup" } })
    kind = "Group heading"
  elseif record.kind == "claude" then
    local text, hl = state_text(record)
    table.insert(rows, { { text, hl }, { " · " .. (M.summary(record) or floatterm.name(record)), nil } })
    kind = "Claude tab"
  else
    table.insert(rows, { { "$ " .. floatterm.name(record), nil } })
    kind = M.is_running(record) and (record.command .. " running") or "Terminal"
    if M.is_running(record) and vim.fn.strdisplaywidth(kind) > width then
      long_command = true
      full = full_command_for == record.buf
      if full then
        for _, line in ipairs(wrap(record.command, width)) do
          table.insert(rows, { { line, nil } })
        end
        kind = "running"
      end
    end
  end
  if under > 0 then
    kind = kind .. " · " .. under .. (under == 1 and " tab" or " tabs") .. " under it"
  elseif groups.parent(record) then
    kind = kind .. " · under " .. floatterm.name(groups.parent(record))
  end
  table.insert(rows, { { kind, "FloatTermWorking" } })
  table.insert(rows, { { "", nil } })

  local move = is_horizontal() and "H / L" or "K / J"
  local keys = {
    { "Enter", "open it" },
    { "r", "rename" },
    { "g", "put under another tab" },
  }
  if under > 0 then
    table.insert(keys, {
      "za",
      (record.children_folded and "unfold its " or "fold its ")
        .. under
        .. (under == 1 and " tab" or " tabs")
        .. (record.children_folded and "" or " away"),
    })
  end
  if long_command then
    table.insert(keys, { "c", full and "hide the full command" or "show the full command" })
  end
  table.insert(keys, { move, "move earlier / later" })
  local asks = record.kind == "claude" or M.is_running(record)
  table.insert(keys, { "x", asks and "close (asks first)" or "close" })
  for _, key in ipairs(keys) do
    table.insert(rows, { { string.format("%-7s", key[1]), "FloatTermHintKey" }, { key[2], nil } })
  end
  table.insert(rows, { { "", nil } })
  local step = is_horizontal() and "h/l" or "j/k"
  table.insert(rows, { { step .. " move · 1-9 open · Esc back", "FloatTermWorking" } })
  return rows
end

-- Shows the popup beside the selected tab while the cursor is in the bar, and moves it
-- with the selection; closes it otherwise (and while a parent is being picked, when
-- the prompt says what to type).
update_hint = function()
  local span = selected and entries[selected]
  local row = selected and rows_drawn[selected]
  if not (span and row and is_open() and api.nvim_get_current_win() == bar_win and not numbers) then
    close_hint()
    return
  end
  if full_command_for ~= row.record.buf then
    full_command_for = nil
  end
  -- No wider than HINT_WIDTH or the room to the right of where it opens.
  local col
  if is_horizontal() then
    col = math.max(0, span.start_cell or 0)
  else
    col = api.nvim_win_get_width(bar_win) + 1
  end
  local room = vim.o.columns - (api.nvim_win_get_position(bar_win)[2] + col) - 2
  local inner = math.max(20, math.min(HINT_WIDTH, room)) - 2
  local rows = vim.tbl_map(function(chunks)
    return truncate(chunks, inner)
  end, hint_rows(row.record, inner))
  local lines, width = {}, 0
  for n, chunks in ipairs(rows) do
    local text = ""
    for _, chunk in ipairs(chunks) do
      text = text .. chunk[1]
    end
    lines[n] = " " .. text
    width = math.max(width, vim.fn.strdisplaywidth(lines[n]) + 1)
  end
  if not (hint_buf and api.nvim_buf_is_valid(hint_buf)) then
    hint_buf = api.nvim_create_buf(false, true)
  end
  vim.bo[hint_buf].modifiable = true
  api.nvim_buf_set_lines(hint_buf, 0, -1, false, lines)
  vim.bo[hint_buf].modifiable = false
  api.nvim_buf_clear_namespace(hint_buf, hint_ns, 0, -1)
  for n, chunks in ipairs(rows) do
    local col = 1
    for _, chunk in ipairs(chunks) do
      if chunk[2] and #chunk[1] > 0 then
        api.nvim_buf_set_extmark(hint_buf, hint_ns, n - 1, col, { end_col = col + #chunk[1], hl_group = chunk[2] })
      end
      col = col + #chunk[1]
    end
  end

  -- Beside the tab's first line down the left; under its segment along the top.
  local config = { relative = "win", win = bar_win, width = width, height = #lines }
  if is_horizontal() then
    config.row, config.col = 1, col
  else
    local top = api.nvim_win_call(bar_win, function()
      return vim.fn.line "w0"
    end)
    config.row, config.col = span.first - (top - 1) - 1, col
  end
  if hint_win and api.nvim_win_is_valid(hint_win) then
    api.nvim_win_set_config(hint_win, config)
  else
    config.style = "minimal"
    config.border = "rounded"
    config.focusable = false
    config.noautocmd = true
    config.zindex = 60
    hint_win = api.nvim_open_win(hint_buf, false, config)
    vim.wo[hint_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatTermHintBorder"
  end
end

function M.hint_window()
  return hint_win and api.nvim_win_is_valid(hint_win) and hint_win or nil
end

-- The popup's text, one string per line ({} when it isn't showing). For tests.
function M.hint_lines()
  if not (hint_win and api.nvim_win_is_valid(hint_win)) then
    return {}
  end
  return vim.tbl_map(vim.trim, api.nvim_buf_get_lines(hint_buf, 0, -1, false))
end

local pending = false
-- Redraws once after whatever else is happening, so a burst of events draws once.
local function schedule_redraw()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    M.redraw()
  end)
end

-- Shows a number beside each tab in `map` (record -> number), for picking one by
-- typing it; nil takes them away. Returns whether the bar is showing.
function M.show_numbers(map)
  numbers = map
  M.redraw()
  return is_open()
end

-- The bar's text, one string per line. For tests and debugging.
function M.lines()
  if not (bar_buf and api.nvim_buf_is_valid(bar_buf) and is_open()) then
    return {}
  end
  return api.nvim_buf_get_lines(bar_buf, 0, -1, false)
end

function M.window()
  return is_open() and bar_win or nil
end

local function tab_at_line(line)
  for i, span in ipairs(entries) do
    if line >= span.first and line <= span.last then
      return i
    end
  end
  return nil
end

local function tab_at_cell(cell)
  for i, span in ipairs(entries) do
    if cell >= span.start_cell and cell < span.end_cell then
      return i
    end
  end
  return nil
end

local function selected_record()
  local row = selected and rows_drawn[selected]
  return row and row.record or nil
end

-- Selects the row `record` is drawn on.
local function select_record(record)
  M.redraw()
  local i = require("floatterm.groups").row_of(rows_drawn, record)
  if i then
    selected = i
    M.redraw()
  end
end

local function select(delta)
  local count = #rows_drawn
  if count == 0 then
    return
  end
  selected = math.max(1, math.min(count, (selected or 1) + delta))
  M.redraw()
end

-- Back to the terminal, typing.
local function leave()
  local win = require("floatterm").window()
  if win then
    api.nvim_set_current_win(win)
    vim.cmd "startinsert"
  end
end

local function open_selected()
  local record = selected_record()
  if record then
    require("floatterm").focus_buf(record.buf)
  end
end

local function close_selected()
  local record = selected_record()
  if not record then
    return
  end
  local floatterm = require "floatterm"
  local reason = nil
  if record.kind == "claude" then
    reason = "Claude session"
  elseif M.is_running(record) then
    reason = record.command .. " is running"
  end
  if not reason then
    floatterm.close_tab(record.buf)
    return
  end

  local name = floatterm.name(record)
  vim.ui.select({ "Close it", "Keep it" }, { prompt = "Close " .. name .. " (" .. reason .. ")?" }, function(choice)
    if choice == "Close it" then
      floatterm.close_tab(record.buf)
    end
  end)
end

local function rename_selected()
  local record = selected_record()
  if not record then
    return
  end
  local floatterm = require "floatterm"
  vim.ui.input({ prompt = "Tab name: ", default = floatterm.name(record) }, function(input)
    input = input and vim.trim(input) or ""
    if input ~= "" then
      floatterm.update(record.buf, { label = input })
    end
  end)
end

function M.map_bar_keys(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  end
  map("j", function()
    select(1)
  end, "tab bar next tab")
  map("k", function()
    select(-1)
  end, "tab bar previous tab")
  map("<Down>", function()
    select(1)
  end, "tab bar next tab")
  map("<Up>", function()
    select(-1)
  end, "tab bar previous tab")
  map("l", function()
    select(1)
  end, "tab bar next tab")
  map("h", function()
    select(-1)
  end, "tab bar previous tab")
  map("<CR>", open_selected, "tab bar open tab")
  -- Capitals move the selected tab itself along (with its children, among its
  -- siblings), and the selection with it.
  for lhs, delta in pairs { K = -1, H = -1, J = 1, L = 1 } do
    map(lhs, function()
      local record = selected_record()
      if record then
        require("floatterm").move_tab(record.buf, delta)
        select_record(record)
      end
    end, "tab bar move tab " .. (delta < 0 and "earlier" or "later"))
  end
  -- g puts the tab under another (or under none); za folds a parent's children. g
  -- doesn't wait for a second key, so gg isn't the top here (k or 1 is).
  map("g", function()
    local record = selected_record()
    if record then
      require("floatterm.groups").pick_parent(record.buf)
    end
  end, "tab bar put this tab under another")
  map("za", function()
    local record = selected_record()
    local folded = record and require("floatterm.groups").toggle_fold(record.buf)
    if folded then
      select_record(folded)
    end
  end, "tab bar fold or unfold this tab's children")
  for n = 1, 9 do
    map(tostring(n), function()
      local row = rows_drawn[n]
      local record = row and row.record
      if record then
        leave()
        require("floatterm").focus_buf(record.buf)
      end
    end, "tab bar open tab " .. n)
  end
  map("x", close_selected, "tab bar close tab")
  map("r", rename_selected, "tab bar rename tab")
  -- Only does something when the popup offers it (a command too long to show).
  map("c", function()
    local record = selected_record()
    if record then
      full_command_for = full_command_for ~= record.buf and record.buf or nil
      update_hint()
    end
  end, "tab bar show or hide the full command")
  map("<Esc>", leave, "tab bar back to the terminal")
  map("q", leave, "tab bar back to the terminal")

  -- Other motions (gg, G, a click) still say which tab the cursor is on.
  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if not is_open() or api.nvim_get_current_win() ~= bar_win then
        return
      end
      local cursor = api.nvim_win_get_cursor(bar_win)
      local i
      if is_horizontal() then
        local cell = vim.fn.strdisplaywidth(api.nvim_get_current_line():sub(1, cursor[2]))
        i = tab_at_cell(cell)
      else
        i = tab_at_line(cursor[1] - 1)
      end
      if i and i ~= selected then
        selected = i
        M.redraw()
      end
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function()
      close_hint()
      vim.schedule(function()
        if is_open() and api.nvim_get_current_win() ~= bar_win then
          selected = nil
          api.nvim_win_set_config(bar_win, { focusable = false })
          M.redraw()
        end
      end)
    end,
  })
end

-- Moves the cursor into the bar, on the tab showing.
function M.enter()
  M.redraw()
  if not is_open() then
    vim.notify("floatterm: the tab bar is off, or there's no room for it", vim.log.levels.INFO)
    return
  end
  local floatterm = require "floatterm"
  selected = require("floatterm.groups").row_of(rows_drawn, floatterm.record(floatterm.current_buf() or -1)) or 1
  api.nvim_win_set_config(bar_win, { focusable = true })
  api.nvim_set_current_win(bar_win)
  M.redraw()
end

-- The screen cells a float covers, border included: top, left, bottom, right (0-based,
-- inclusive).
local function float_cells(win, config)
  local pos = api.nvim_win_get_position(win)
  local border = type(config.border) == "table" and #config.border > 0 and 2 or 0
  return pos[1], pos[2], pos[1] + config.height + border - 1, pos[2] + config.width + border - 1
end

-- True when another float is drawn over the bar at this cell. Neovim reports the
-- focusable window under the mouse (never the bar, which can't be focused), so one
-- found there at the bar's zindex or above is on top of it; a float that can't be
-- focused counts when it's strictly above.
local function covered(pos, row, cell)
  local bar_z = api.nvim_win_get_config(bar_win).zindex or 50
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local config = api.nvim_win_get_config(win)
    if win ~= bar_win and config.relative ~= "" then
      local z = config.zindex or 50
      local top, left, bottom, right = float_cells(win, config)
      local inside = row >= top and row <= bottom and cell >= left and cell <= right
      if inside and (z > bar_z or (win == pos.winid and z == bar_z)) then
        return true
      end
    end
  end
  return false
end

-- A click on a tab in the bar opens it. The bar can't be focused, so the click is
-- matched to the bar by where it landed on screen, and only counts when the bar is on
-- this tab page and nothing is drawn over it there; anywhere else the click (and any
-- drag that follows) does what it always does.
local function on_click()
  local floatterm = package.loaded["floatterm"]
  if not (floatterm and is_open()) or api.nvim_win_get_tabpage(bar_win) ~= api.nvim_get_current_tabpage() then
    return "<LeftMouse>"
  end
  local pos = vim.fn.getmousepos()
  local row, cell = pos.screenrow - 1, pos.screencol - 1
  local config = api.nvim_win_get_config(bar_win)
  local top, left, bottom, right = float_cells(bar_win, config)
  -- Inside the border, when the bar has one (down the left side).
  local edge = (top + config.height - 1 < bottom) and 1 or 0
  if row < top + edge or row > bottom - edge or cell < left + edge or cell > right - edge then
    return "<LeftMouse>"
  end
  if covered(pos, row, cell) then
    return "<LeftMouse>"
  end
  local i
  if is_horizontal() then
    i = tab_at_cell(cell - left)
  else
    local first = api.nvim_win_call(bar_win, function()
      return vim.fn.line "w0"
    end)
    i = tab_at_line(row - top - edge + first - 1)
  end
  -- On the bar between tabs: nothing to open, and the window under the bar isn't the
  -- one clicked.
  if not i then
    return ""
  end
  local record = rows_drawn[i] and rows_drawn[i].record
  if not record then
    return ""
  end
  -- Typing carries on if you were typing in the terminal; otherwise (Ctrl+x, or from
  -- the code) the tab opens in normal mode, and i starts typing.
  local typing = api.nvim_get_mode().mode == "t"
  vim.schedule(function()
    floatterm.focus_buf(record.buf, { typing = typing })
  end)
  return ""
end

-- Each shell tab's shell process id, by buffer.
local function shell_pids(tabs)
  local pids = {}
  for _, record in ipairs(tabs) do
    if record.kind ~= "claude" and record.job then
      local ok, pid = pcall(vim.fn.jobpid, record.job)
      if ok and pid and pid > 0 then
        pids[record.buf] = pid
      end
    end
  end
  return pids
end

-- `ps` output as { [pid] = { tpgid, args } }, or { [pid] = args } without tpgid.
local function parse_ps(stdout, with_tpgid)
  local found = {}
  for line in (stdout or ""):gmatch "[^\n]+" do
    if with_tpgid then
      local pid, tpgid, args = line:match "^%s*(%d+)%s+(-?%d+)%s+(.*)$"
      if pid then
        found[tonumber(pid)] = { tpgid = tonumber(tpgid), args = args }
      end
    else
      local pid, args = line:match "^%s*(%d+)%s+(.*)$"
      if pid then
        found[tonumber(pid)] = args
      end
    end
  end
  return found
end

-- Sets each shell tab's command from what `ps` found: its shell when it's waiting at
-- the prompt, else the leader of its terminal's foreground group.
local function apply_commands(pids, shells, leaders)
  local floatterm = package.loaded["floatterm"]
  if not floatterm then
    return
  end
  for buf, pid in pairs(pids) do
    local shell = shells[pid]
    if shell and floatterm.record(buf) then
      local name = tidy(shell.args):match "^(%S+)"
      local own = shell.tpgid == pid or shell.tpgid <= 0
      idle[buf] = own and SHELLS[name] == true
      local command
      if idle[buf] then
        command = name
      else
        ran[buf] = true
        local leader = own and shell.args or leaders[shell.tpgid]
        command = leader and tidy(leader) or floatterm.record(buf).command
      end
      floatterm.update(buf, { command = command })
    end
  end
end

-- One `ps` for every shell tab's terminal foreground process group, then one for the
-- leaders of those groups. An idle shell is its own foreground group.
local function refresh_commands(tabs)
  if busy then
    return
  end
  local pids = shell_pids(tabs)
  if vim.tbl_isempty(pids) then
    return
  end

  local function finish(shells, leaders)
    vim.schedule(function()
      busy = false
      apply_commands(pids, shells, leaders)
      schedule_redraw()
    end)
  end

  -- Any error between here and finish clears busy, or no `ps` would ever run again.
  local function guarded(fn)
    return function(...)
      local ok = pcall(fn, ...)
      if not ok then
        busy = false
      end
    end
  end

  busy = true
  M.ps_runs = M.ps_runs + 1
  local list = table.concat(vim.tbl_values(pids), ",")
  local ps = { "ps", "-o", "pid=,tpgid=,args=", "-p", list }
  local ok = pcall(
    vim.system,
    ps,
    { text = true },
    guarded(function(first)
      local shells = parse_ps(first.stdout, true)
      local groups = {}
      for pid, shell in pairs(shells) do
        if shell.tpgid > 0 and shell.tpgid ~= pid then
          groups[shell.tpgid] = true
        end
      end
      if vim.tbl_isempty(groups) then
        finish(shells, {})
        return
      end
      local leaders_list = table.concat(vim.tbl_keys(groups), ",")
      local leaders_ps = { "ps", "-o", "pid=,args=", "-p", leaders_list }
      local started = pcall(
        vim.system,
        leaders_ps,
        { text = true },
        guarded(function(second)
          finish(shells, parse_ps(second.stdout, false))
        end)
      )
      if not started then
        finish(shells, {})
      end
    end)
  )
  if not ok then
    busy = false
  end
end

-- Brings every shell tab's command up to date with `ps`, without waiting for it: the
-- records change (and FloatTermTabChanged fires) once it answers. lua/floatterm/restore
-- calls it for its periodic save, as `ps` otherwise only runs while the bar is drawn or
-- a Claude tab exists. Does nothing with no shell tabs or a `ps` still running, and
-- leaves the records as they were if `ps` fails.
function M.refresh()
  local floatterm = package.loaded["floatterm"]
  refresh_commands(floatterm and floatterm.tabs() or {})
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Copies each tab's terminal title into its record and refreshes shell commands.
function M.tick()
  local floatterm = package.loaded["floatterm"]
  local tabs = floatterm and floatterm.tabs() or {}
  if #tabs == 0 then
    stop_timer()
    return
  end
  for _, record in ipairs(tabs) do
    if api.nvim_buf_is_valid(record.buf) then
      local title = vim.b[record.buf].term_title
      if type(title) == "string" and title ~= "" and not title:match "^term://" then
        floatterm.update(record.buf, { title = title })
      end
    end
  end
  -- `ps` runs only while the bar is drawn or a Claude tab exists, not for shells
  -- nobody can see.
  local has_claude = false
  for _, record in ipairs(tabs) do
    has_claude = has_claude or record.kind == "claude"
  end
  if is_open() or has_claude then
    refresh_commands(tabs)
  end
  -- Times in the bar move on even when nothing else changes.
  if is_open() then
    schedule_redraw()
  end
end

local function start_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(INTERVAL, INTERVAL, vim.schedule_wrap(M.tick))
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true
  require("floatterm.groups").setup()

  local group = api.nvim_create_augroup("floatterm_tabbar", { clear = true })
  local keys_added = false
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FloatTermLayoutChanged", "FloatTermTabsChanged", "FloatTermTabChanged", "FloatTermSettingsChanged" },
    callback = function(args)
      local floatterm = package.loaded["floatterm"]
      if args.match == "FloatTermTabsChanged" and floatterm then
        if not keys_added then
          keys_added = true
          floatterm.add_tab_key("<C-S-b>", M.enter, "terminal move into the tab bar")
        end
        if #floatterm.tabs() > 0 then
          start_timer()
        else
          stop_timer()
        end
      end
      if args.match == "FloatTermLayoutChanged" and not args.data.open then
        close()
        return
      end
      schedule_redraw()
    end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  api.nvim_create_autocmd("VimResized", { group = group, callback = schedule_redraw })
  vim.keymap.set(
    { "n", "i", "t", "x" },
    "<LeftMouse>",
    on_click,
    { expr = true, desc = "terminal open the tab clicked in the tab bar" }
  )
end

return M
