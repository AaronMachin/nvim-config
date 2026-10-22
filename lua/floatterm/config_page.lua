-- The floating terminal's configuration page: one row per setting in
-- lua/floatterm/settings, opened with :FloatTermSettings or Ctrl+Shift+, from inside
-- the terminal.
--
-- j/k move between rows, ←/→ (or h/l) change the value, Enter cycles a choice or asks
-- for a number, q or Esc closes. Every change goes straight through settings.set, so
-- the float and anything drawn on it follow at once, and is saved for this machine.

local M = {}

local api = vim.api
local settings = require "floatterm.settings"

local ns = api.nvim_create_namespace "floatterm_config_page"

local HEADER = "Terminal settings"
local HINTS = "←/→ change · Enter cycles · q closes"
local LABEL_WIDTH = 22
-- Header and blank line above the first setting.
local FIRST_ROW = 3

-- One entry per setting, in the order shown. A choice lists its values with the label
-- shown for each; a number gives its bounds and how far ←/→ moves it. Docked sizes are
-- two numbers kept as fractions but shown and typed as percentages; Tab picks which one
-- ←/→ and Enter change.
local ROWS = {
  {
    key = "tabbar",
    label = "Tab bar",
    choices = { { "left", "left" }, { "top", "top" }, { "off", "off" } },
  },
  { key = "tabbar_width", label = "Tab bar width", number = { min = 16, max = 60, step = 2 } },
  {
    key = "start_position",
    label = "Starting position",
    choices = { { "bottom", "bottom" }, { "top", "top" }, { "left", "left" }, { "right", "right" }, { "box", "box" }, { "split", "split" } },
    -- The float only reads it when nvim starts.
    note = "from the next nvim",
  },
  {
    key = "dock_sizes",
    label = "Docked sizes",
    parts = {
      { name = "large", min = 10, max = 95, step = 5 },
      { name = "small", min = 10, max = 95, step = 5 },
    },
    note = "Tab: large/small",
  },
  { key = "hints", label = "Key hints", choices = { { true, "shown" }, { false, "hidden" } } },
  { key = "reopen_tabs", label = "Reopen tabs on start", choices = { { true, "yes" }, { false, "no" } } },
  { key = "bookmark", label = "Claude bookmark", choices = { { true, "shown" }, { false, "hidden" } } },
}

local page = nil

local function percent(fraction)
  return math.floor(fraction * 100 + 0.5)
end

-- The bounds for one docked size: large stays above small, and small below large.
local function part_bounds(part, sizes)
  if part.name == "large" then
    return math.max(part.min, percent(sizes.small) + 1), part.max
  end
  return part.min, math.min(part.max, percent(sizes.large) - 1)
end

local function choice_index(row, value)
  for i, choice in ipairs(row.choices) do
    if choice[1] == value then
      return i
    end
  end
  return 1
end

-- A row's text and its highlights as { from, to, group } byte ranges. The value ←/→
-- changes sits in ‹ ›; other choices are dimmed.
local function render_row(row, selected)
  local text = " " .. row.label .. string.rep(" ", LABEL_WIDTH - #row.label)
  local marks = {}

  local function add(piece, group, marked)
    local before = marked and "‹ " or "  "
    local after = marked and " ›" or "  "
    local from = #text + #before
    text = text .. before .. piece .. after
    table.insert(marks, { from, from + #piece, group })
  end

  local value = settings.get(row.key)
  if row.choices then
    local current = choice_index(row, value)
    for i, choice in ipairs(row.choices) do
      add(choice[2], i == current and "FloatTermSettingsValue" or "Comment", i == current)
    end
  elseif row.number then
    add(tostring(value), "FloatTermSettingsValue", selected)
  else
    for i, part in ipairs(row.parts) do
      add(part.name .. " " .. percent(value[part.name]) .. "%", "FloatTermSettingsValue", selected and page.part == i)
    end
  end

  if row.note then
    local from = #text + 2
    text = text .. "  " .. row.note
    table.insert(marks, { from, #text, "Comment" })
  end
  return text, marks
end

local function page_open()
  return page ~= nil and api.nvim_win_is_valid(page.win)
end

-- Clamped, as a mouse click can put the cursor on the header.
local function selected_row()
  local row = api.nvim_win_get_cursor(page.win)[1] - FIRST_ROW + 1
  return math.min(#ROWS, math.max(1, row))
end

local function draw()
  if not page_open() then
    return
  end

  local current = selected_row()
  local lines, all_marks = {}, {}
  for i, row in ipairs(ROWS) do
    local text, marks = render_row(row, i == current)
    lines[i] = text
    all_marks[i] = marks
  end

  local width = vim.fn.strdisplaywidth(" " .. HEADER .. "  " .. HINTS .. " ")
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
  end
  local gap = width - vim.fn.strdisplaywidth(" " .. HEADER .. HINTS .. " ")
  local header = " " .. HEADER .. string.rep(" ", gap) .. HINTS .. " "

  vim.bo[page.buf].modifiable = true
  api.nvim_buf_set_lines(page.buf, 0, -1, false, vim.list_extend({ header, "" }, lines))
  vim.bo[page.buf].modifiable = false

  api.nvim_buf_clear_namespace(page.buf, ns, 0, -1)
  api.nvim_buf_add_highlight(page.buf, ns, "Title", 0, 1, 1 + #HEADER)
  api.nvim_buf_add_highlight(page.buf, ns, "Comment", 0, #header - #HINTS - 1, -1)
  for i, marks in ipairs(all_marks) do
    for _, mark in ipairs(marks) do
      api.nvim_buf_add_highlight(page.buf, ns, mark[3], FIRST_ROW + i - 2, mark[1], mark[2])
    end
  end

  -- Centred over the editor, whatever size it is now.
  local height = #lines + 2
  api.nvim_win_set_config(page.win, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
  })
end

local function move(by)
  local row = math.min(#ROWS, math.max(1, selected_row() + by))
  page.part = 1
  api.nvim_win_set_cursor(page.win, { FIRST_ROW + row - 1, 0 })
  draw()
end

-- Sets a number row (or the selected docked size) to `wanted`. Stepping clamps to the
-- bounds; a typed number outside them is refused with the bounds, so it isn't quietly
-- changed into something else.
local function set_number(row, wanted, typed)
  if row.number then
    local bounds = row.number
    if typed and (wanted < bounds.min or wanted > bounds.max) then
      vim.notify(("%s must be %d to %d"):format(row.label, bounds.min, bounds.max), vim.log.levels.WARN)
      return
    end
    settings.set(row.key, math.min(bounds.max, math.max(bounds.min, wanted)))
    return
  end

  local sizes = vim.deepcopy(settings.get(row.key))
  local part = row.parts[page.part]
  local low, high = part_bounds(part, sizes)
  if typed and (wanted < low or wanted > high) then
    vim.notify(("The %s docked size must be %d%% to %d%%"):format(part.name, low, high), vim.log.levels.WARN)
    return
  end
  sizes[part.name] = math.min(high, math.max(low, wanted)) / 100
  settings.set(row.key, sizes)
end

local function current_number(row)
  if row.number then
    return settings.get(row.key), row.number.step
  end
  local part = row.parts[page.part]
  return percent(settings.get(row.key)[part.name]), part.step
end

-- ←/→ (direction -1 or 1): the next choice that way, stopping at the ends, or a step.
local function change(direction)
  local row = ROWS[selected_row()]
  if row.choices then
    local i = choice_index(row, settings.get(row.key)) + direction
    if i >= 1 and i <= #row.choices then
      settings.set(row.key, row.choices[i][1])
    end
    return
  end

  local value, step = current_number(row)
  set_number(row, value + direction * step, false)
end

-- Enter: the next choice, wrapping round, or a prompt for a number.
local function enter()
  local row = ROWS[selected_row()]
  if row.choices then
    local i = choice_index(row, settings.get(row.key)) % #row.choices + 1
    settings.set(row.key, row.choices[i][1])
    return
  end

  local value = current_number(row)
  local name = row.number and row.label or (row.label .. ", " .. row.parts[page.part].name .. " (%)")
  -- A prompt in its own window would otherwise count as leaving the page.
  page.prompting = true
  vim.ui.input({ prompt = name .. ": ", default = tostring(value) }, function(input)
    if page then
      page.prompting = false
    end
    local wanted = input and tonumber((input:gsub("%%", "")))
    if not wanted or not page_open() then
      return
    end
    set_number(row, math.floor(wanted + 0.5), true)
    draw()
  end)
end

-- Tab on the docked sizes row moves between large and small.
local function next_part()
  local row = ROWS[selected_row()]
  if row.parts then
    page.part = page.part % #row.parts + 1
    draw()
  end
end

-- Closes the page. Unless `stay` (you've already gone to another window), it returns
-- you to the window you opened it from.
local function close(stay)
  if not page then
    return
  end

  local closing = page
  page = nil
  api.nvim_del_augroup_by_id(closing.group)
  if api.nvim_win_is_valid(closing.win) then
    api.nvim_win_close(closing.win, true)
  end
  if stay or not api.nvim_win_is_valid(closing.return_win) then
    return
  end
  api.nvim_set_current_win(closing.return_win)
  -- Opened from a terminal tab you were typing in and it's still showing, so carry on
  -- typing.
  if closing.was_terminal and api.nvim_win_get_buf(closing.return_win) == closing.return_buf then
    vim.cmd "startinsert"
  end
end

function M.close()
  close(false)
end

function M.is_open()
  return page_open()
end

-- The page's lines, for tests.
function M.lines()
  return page_open() and api.nvim_buf_get_lines(page.buf, 0, -1, false) or {}
end

function M.open()
  if page_open() then
    api.nvim_set_current_win(page.win)
    return
  end

  local return_win = api.nvim_get_current_win()
  local return_buf = api.nvim_get_current_buf()
  local was_terminal = api.nvim_get_mode().mode == "t" and vim.bo[return_buf].buftype == "terminal"

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "floatterm_settings"

  -- Above the floating terminal (zindex 50) and its hints.
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 1,
    style = "minimal",
    border = "rounded",
    zindex = 200,
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  if was_terminal then
    vim.cmd "stopinsert"
  end

  page = {
    buf = buf,
    win = win,
    return_win = return_win,
    return_buf = return_buf,
    was_terminal = was_terminal,
    part = 1,
  }
  draw()
  api.nvim_win_set_cursor(win, { FIRST_ROW, 0 })
  draw()

  local function map(keys, fn)
    for _, lhs in ipairs(keys) do
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
    end
  end
  map({ "j", "<Down>" }, function() move(1) end)
  map({ "k", "<Up>" }, function() move(-1) end)
  map({ "l", "<Right>" }, function() change(1) end)
  map({ "h", "<Left>" }, function() change(-1) end)
  map({ "<CR>" }, enter)
  map({ "<Tab>", "<S-Tab>" }, next_part)
  map({ "q", "<Esc>", "<C-S-,>", "<C-lt>" }, M.close)

  page.group = api.nvim_create_augroup("floatterm_config_page", { clear = true })
  api.nvim_create_autocmd("User", { group = page.group, pattern = "FloatTermSettingsChanged", callback = draw })
  api.nvim_create_autocmd("VimResized", { group = page.group, callback = draw })
  -- Going to another window some other way (a mouse click, say) closes the page and
  -- leaves you there.
  api.nvim_create_autocmd("WinLeave", {
    group = page.group,
    buffer = buf,
    callback = function()
      if page and not page.prompting then
        vim.schedule(function()
          close(true)
        end)
      end
    end,
  })
end

function M.setup()
  api.nvim_set_hl(0, "FloatTermSettingsValue", { link = "Special", default = true })

  api.nvim_create_user_command("FloatTermSettings", M.open, { desc = "Floating terminal settings page" })

  -- Terminals speaking the kitty keyboard protocol send Ctrl+Shift+, as <C-S-,>; ones
  -- that send the shifted key instead give <C-lt> (Ctrl+<).
  local floatterm = require "floatterm"
  floatterm.add_tab_key("<C-S-,>", M.open, "terminal settings page")
  floatterm.add_tab_key("<C-lt>", M.open, "terminal settings page")
end

return M
