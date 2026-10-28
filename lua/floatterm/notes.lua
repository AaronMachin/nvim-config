-- A notes pane beside the floating terminal, one set of notes per tab.
--
-- Notes are opt-in per tab (M.toggle_notes). A tab with notes gets a note_id
-- (YYYYMMDD-xxxx) and two files in <folder>/.nvim/fterm/notes/, where <folder> is the
-- folder nvim was started in:
--   <note_id>.md         yours: an ordinary markdown file, saved as you go
--   <note_id>.claude.md  Claude's, written by lua/floatterm/claude_notes after its turns,
--                        which then fires User FloatTermClaudeNotesChanged { note_id }
-- Switching notes off only hides the pane; the files stay, and lua/floatterm/restore
-- keeps the note_id with the tab. Yours is deleted when its tab closes with nothing in
-- it but the heading it started with.
--
-- The pane fills the box lua/floatterm keeps for it (layout().notes): beside the float,
-- or over the empty window the split placement keeps for it. It's drawn as floats over
-- that box, in the same way as the tab bar, so every placement draws it the same way:
-- Claude's part on top when there is one, yours below. Where there's no box (the
-- floating box placement, or no room), Ctrl+Shift+e shows it over the terminal
-- instead, until Ctrl+Shift+e or Esc goes back. A prompt or picker opened from the
-- notes (<leader>o a, <leader>o o) doesn't put them away.
--
-- Going into yours puts the cursor on an empty line at the end, typing. Claude's part
-- shows what fits, and its title says how many lines don't; Ctrl+Shift+o in yours
-- shows all of it in a large float to scroll and copy from.
--
-- Captures go at the end of yours: Y on a selection in a terminal tab, <leader>o y on
-- a selection in code, <leader>o a for a one-line note.

local M = {}

local api = vim.api
local settings = require "floatterm.settings"

local CLAUDE_EMPTY = "Claude's notes appear after its next turn"
local SIDES = {
  { "<C-S-h>", "<C-S-Left>", "left" },
  { "<C-S-l>", "<C-S-Right>", "right" },
  { "<C-S-k>", "<C-S-Up>", "top" },
  { "<C-S-j>", "<C-S-Down>", "bottom" },
}

-- The folder nvim was started in, found once. A field so tests can point it elsewhere.
M.folder = nil

-- The pane's windows, the tab buffer whose notes they show, whether they're shown over
-- the terminal rather than in a box of their own, and whether the cursor has gone from
-- yours into a prompt or popup it'll come back from.
local pane = { mine = nil, claude = nil, buf = nil, overlay = false, away = false }
-- Claude's part of each note, by note_id: a scratch buffer holding the file's text.
local claude_bufs = {}
-- Buffers whose keys are set: notes buffers, and terminal tabs (for Y).
local configured = {}
local tab_keys = {}
-- The heading each note of yours was made with in this nvim, by note_id, so one
-- you've changed isn't taken for empty.
local created = {}
-- Set while the pane closes its own windows, so WinClosed can tell those from a :q.
local closing = false
-- The window the cursor was last in before the one it's in now. Kept on WinLeave, as
-- WinEnter can't ask once a prompt has closed and taken its window with it.
local left = nil
-- Ctrl+Shift+h/j/k/l towards the side the pane is already on steps through these.
local SHARES = { 0.25, 0.35, 0.5 }

local function folder()
  if not M.folder then
    -- As lua/floatterm/restore: nvim opened on one folder means that folder.
    local start = vim.uv.cwd()
    if vim.fn.argc() == 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
      start = vim.fn.argv(0)
    end
    M.folder = vim.uv.fs_realpath(start) or vim.uv.cwd()
  end
  return M.folder
end

function M.dir()
  return folder() .. "/.nvim/fterm/notes"
end

local function paths_for(note_id)
  local base = M.dir() .. "/" .. note_id
  return { mine = base .. ".md", claude = base .. ".claude.md" }
end

-- A tab's notes files, { mine, claude }, or nil when it has no notes. Makes the folder
-- they go in.
function M.paths(record)
  if not (record and record.note_id) then
    return nil
  end
  vim.fn.mkdir(M.dir(), "p")
  return paths_for(record.note_id)
end

local function read_lines(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read "*a"
  file:close()
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return lines
end

local function new_id()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  while true do
    local bytes = vim.uv.random(4)
    local suffix = bytes:gsub(".", function(c)
      local i = c:byte() % #chars + 1
      return chars:sub(i, i)
    end)
    local id = os.date "%Y%m%d" .. "-" .. suffix
    if not vim.uv.fs_stat(paths_for(id).mine) then
      return id
    end
  end
end

local function floatterm()
  return require "floatterm"
end

local function save(buf)
  if buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    api.nvim_buf_call(buf, function()
      vim.cmd "silent! update"
    end)
  end
end

local function in_pane(win)
  return win ~= nil and (win == pane.mine or win == pane.claude)
end

-- The tab notes commands act on: the tab you're in, the one whose notes you're in, or
-- the one the float last showed.
local function target_record()
  local ft = floatterm()
  local here = ft.record(api.nvim_get_current_buf())
  if here then
    return here
  end
  if in_pane(api.nvim_get_current_win()) and pane.buf then
    return ft.record(pane.buf)
  end
  return ft.record(ft.current_buf() or -1)
end

-- Gives a tab a note_id if it has none, and its file with a heading if there's none.
local function ensure_note(record)
  if not record.note_id then
    floatterm().update(record.buf, { note_id = new_id() })
  end
  local paths = M.paths(record)
  if not vim.uv.fs_stat(paths.mine) then
    local heading = "# " .. floatterm().name(record)
    local file = io.open(paths.mine, "w")
    if file then
      file:write(heading .. "\n")
      file:close()
      created[record.note_id] = heading
    end
  end
  return paths
end

local set_up_buffer

-- Your notes as a buffer on the file, loaded but kept out of the buffer list.
local function mine_buf(record)
  local paths = ensure_note(record)
  local buf = vim.fn.bufadd(paths.mine)
  if not api.nvim_buf_is_loaded(buf) then
    -- Saved as you go, so a swap file only gets in the way of another nvim here.
    vim.bo[buf].swapfile = false
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "hide"
  if vim.bo[buf].filetype ~= "markdown" then
    vim.bo[buf].filetype = "markdown"
  end
  if not configured[buf] then
    configured[buf] = true
    set_up_buffer(buf, true)
  end
  return buf
end

-- Reads Claude's file into its buffer.
local function load_claude(note_id)
  local buf = claude_bufs[note_id]
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = read_lines(paths_for(note_id).claude) or {}
  local empty = #lines == 0
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, empty and { CLAUDE_EMPTY } or lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.b[buf].floatterm_notes_empty = empty
end

local function claude_buf(note_id)
  local buf = claude_bufs[note_id]
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "markdown"
    claude_bufs[note_id] = buf
    set_up_buffer(buf, false)
    load_claude(note_id)
  end
  return buf
end

local function close_win(win)
  closing = true
  pcall(api.nvim_win_close, win, true)
  closing = false
end

local function close_windows()
  for _, key in ipairs { "mine", "claude" } do
    local win = pane[key]
    if win and api.nvim_win_is_valid(win) then
      if key == "mine" then
        save(api.nvim_win_get_buf(win))
      end
      close_win(win)
    end
    pane[key] = nil
  end
end

local function close()
  close_windows()
  pane.buf = nil
  pane.overlay = false
end

-- Opens a pane window, or moves an open one, onto `buf`.
local function place(key, buf, config, winhighlight)
  local win = pane[key]
  if win and api.nvim_win_is_valid(win) then
    if api.nvim_win_get_buf(win) ~= buf then
      api.nvim_win_set_buf(win, buf)
    end
    api.nvim_win_set_config(win, config)
  else
    win = api.nvim_open_win(buf, false, vim.tbl_extend("force", config, { style = "minimal", noautocmd = true }))
    pane[key] = win
  end
  -- Again on every draw: showing another buffer in the window brings back the options
  -- it last had there.
  for option, value in pairs {
    wrap = true,
    linebreak = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    cursorline = false,
    spell = false,
    list = false,
    winhighlight = winhighlight or "",
  } do
    vim.wo[win][option] = value
  end
end

-- How many screen lines a buffer takes at `width` columns, wrapped.
local function display_lines(buf, width)
  local count = 0
  for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    count = count + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return count
end

-- Claude's part's title: with how many lines don't fit and the key that shows them
-- all, shortened when the part is narrow.
local function claude_title(hidden, width)
  if hidden > 0 then
    for _, title in ipairs {
      (" ✳ Claude · %d more %s · Ctrl+Shift+o "):format(hidden, hidden == 1 and "line" or "lines"),
      (" ✳ Claude · %d more · C-S-o "):format(hidden),
    } do
      if vim.fn.strdisplaywidth(title) <= width then
        return title
      end
    end
  end
  return " ✳ Claude "
end

-- Draws a tab's notes into `box` (border included, editor rows): Claude's part on top
-- for a Claude tab (with Claude's notes on) or once Claude has written some, yours
-- below.
local function draw(record, box, overlay)
  local paths = M.paths(record)
  local mine = mine_buf(record)
  local width = math.max(1, box.width - 2)
  local zindex = overlay and 60 or 50
  local show_claude = ((record.kind == "claude" and settings.get "claude_notes") or vim.uv.fs_stat(paths.claude) ~= nil)
    and box.height >= 6

  local top, height = box.row, box.height
  if show_claude then
    local cbuf = claude_buf(record.note_id)
    -- Yours keeps at least one line.
    -- Claude's part takes up to the claude_notes_share setting of the pane, less when
    -- it's short.
    local room = math.max(1, math.min(math.floor(box.height * settings.get "claude_notes_share") - 2, box.height - 5))
    local config = {
      relative = "editor",
      row = box.row,
      col = box.col,
      width = width,
      height = math.max(1, math.min(room, display_lines(cbuf, width))),
      border = "rounded",
      title = " ✳ Claude ",
      title_pos = "center",
      zindex = zindex,
    }
    place("claude", cbuf, config, vim.b[cbuf].floatterm_notes_empty and "NormalFloat:Comment" or nil)
    -- Counted again in the window: wrapping at word breaks can take more lines than
    -- the estimate.
    local total = api.nvim_win_text_height(pane.claude, {}).all
    config.height = math.max(1, math.min(room, total))
    config.title = claude_title(total - config.height, width)
    api.nvim_win_set_config(pane.claude, config)
    top, height = box.row + config.height + 2, box.height - config.height - 2
  elseif pane.claude and api.nvim_win_is_valid(pane.claude) then
    close_win(pane.claude)
    pane.claude = nil
  end

  place("mine", mine, {
    relative = "editor",
    row = top,
    col = box.col,
    width = width,
    height = math.max(1, height - 2),
    border = "rounded",
    title = overlay and (" yours · " .. floatterm().name(record) .. " ") or " yours ",
    title_pos = "center",
    footer = overlay and " Esc or Ctrl+Shift+e goes back " or "",
    footer_pos = "center",
    zindex = zindex,
  })
end

-- Draws the pane for the tab showing, or closes it when the float is hidden or that
-- tab has notes off.
function M.redraw()
  local ft = package.loaded["floatterm"]
  if not ft then
    return
  end
  local layout = ft.layout()
  local record = ft.record(ft.current_buf() or -1)
  if not (layout.open and record and record.notes_on and record.note_id) then
    close()
    return
  end
  -- As the tab bar: a float only shows on the tab page it opened on.
  local float_tab = api.nvim_win_get_tabpage(ft.window())
  if pane.mine and api.nvim_win_is_valid(pane.mine) and api.nvim_win_get_tabpage(pane.mine) ~= float_tab then
    close_windows()
  end
  if float_tab ~= api.nvim_get_current_tabpage() then
    return
  end

  -- Shown over the terminal, the notes don't follow to another tab: the terminal is
  -- what that tab shows first.
  if pane.buf ~= record.buf then
    pane.overlay = false
  end
  pane.buf = record.buf

  local box = layout.notes
  if box then
    pane.overlay = false
  elseif pane.overlay then
    box = layout.terminal
  else
    close_windows()
    return
  end
  draw(record, box, pane.overlay)
end

local pending = false
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

-- Switches a tab's notes on (making them if it has none) or off (hiding them).
function M.set(buf, on)
  local ft = floatterm()
  local record = ft.record(buf)
  if not record then
    return
  end
  if on then
    ensure_note(record)
    ft.update(buf, { notes_on = true })
    return
  end
  if pane.buf == buf and in_pane(api.nvim_get_current_win()) then
    M.back()
  end
  if pane.buf == buf then
    close()
  end
  ft.update(buf, { notes_on = false })
end

function M.toggle_notes()
  local record = target_record()
  if not record then
    vim.notify("floatterm: no terminal tab for notes", vim.log.levels.INFO)
    return
  end
  M.set(record.buf, not record.notes_on)
end

-- From the notes back to the terminal, typing.
function M.back()
  if pane.mine and api.nvim_win_is_valid(pane.mine) then
    save(api.nvim_win_get_buf(pane.mine))
  end
  if pane.overlay then
    pane.overlay = false
    close_windows()
  end
  local win = floatterm().window()
  if win then
    api.nvim_set_current_win(win)
    vim.cmd "startinsert"
  end
end

-- Ctrl+Shift+e: between the terminal and its notes, switching them on if they're off.
-- With no box for them, the notes show over the terminal.
function M.toggle_focus()
  if in_pane(api.nvim_get_current_win()) then
    M.back()
    return
  end
  local ft = floatterm()
  local record = target_record()
  if not record then
    vim.notify("floatterm: no terminal tab for notes", vim.log.levels.INFO)
    return
  end
  if not ft.is_showing(record.buf) then
    ft.focus_buf(record.buf)
  end
  if not record.notes_on then
    M.set(record.buf, true)
  end
  pane.buf = record.buf
  pane.overlay = ft.layout().notes == nil
  M.redraw()
  if pane.mine and api.nvim_win_is_valid(pane.mine) then
    -- WinEnter puts the cursor on an empty line at the end, typing.
    api.nvim_set_current_win(pane.mine)
  end
end

-- Ctrl+\ from the notes does what it does from the terminal: hides the float, or in
-- the split goes to the code.
function M.hide_float()
  -- Wherever the cursor lands, it isn't typing into whatever is there.
  vim.cmd "stopinsert"
  local ft = floatterm()
  if pane.mine and api.nvim_win_is_valid(pane.mine) then
    save(api.nvim_win_get_buf(pane.mine))
  end
  local layout = ft.layout()
  if not layout.split then
    ft.hide()
    return
  end
  local terminal = ft.window()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_win_get_config(win).relative == "" and win ~= terminal and win ~= layout.notes_window
      and vim.bo[buf].buftype == "" then
      api.nvim_set_current_win(win)
      return
    end
  end
end

-- The size after `share` in SHARES, going round to the first.
local function next_share(share)
  for _, step in ipairs(SHARES) do
    if step > share + 0.001 then
      return step
    end
  end
  return SHARES[1]
end

-- Ctrl+Shift+h/j/k/l in the notes: towards the side the pane is on makes it bigger
-- (round to the smallest again), another side moves it there. Both are remembered.
local function side_key(side)
  local ft = floatterm()
  if side == settings.get "notes_side" then
    settings.set("notes_share", next_share(settings.get "notes_share"))
  else
    settings.set("notes_side", side)
  end
  -- No longer fitting beside the terminal, the pane shows over it rather than closing
  -- under the cursor.
  if in_pane(api.nvim_get_current_win()) and ft.layout().notes == nil then
    pane.overlay = true
  end
  -- This rebuilds the pane; the cursor stays in it.
  M.redraw()
  if pane.mine and api.nvim_win_is_valid(pane.mine) then
    api.nvim_set_current_win(pane.mine)
  end
end

local function on_escape()
  if pane.overlay then
    M.back()
  else
    vim.cmd "nohlsearch"
  end
end

-- Ctrl+Shift+o in your notes: all of Claude's notes for the tab in a large float, to
-- scroll, select and copy from (y copies to the system clipboard). q or Esc goes back
-- to where you were in yours, typing if you were.
function M.read_claude()
  local from_win, from_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  -- Your notes' file is <note_id>.md.
  local note_id = vim.fn.fnamemodify(api.nvim_buf_get_name(from_buf), ":t"):match "^(.+)%.md$"
  local lines = note_id and read_lines(paths_for(note_id).claude) or {}
  if #lines == 0 then
    vim.notify("No Claude notes for this tab yet", vim.log.levels.INFO)
    return
  end
  local typing = api.nvim_get_mode().mode:sub(1, 1) == "i"
  local cursor = api.nvim_win_get_cursor(from_win)
  if typing then
    vim.cmd "stopinsert"
  end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"

  local width = math.max(20, math.min(100, vim.o.columns - 6))
  local most = math.max(3, math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - 6))
  local record = pane.buf and floatterm().record(pane.buf)
  local config = {
    relative = "editor",
    row = 0,
    col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
    width = width,
    height = most,
    style = "minimal",
    border = "rounded",
    title = record and (" ✳ Claude · " .. floatterm().name(record) .. " ") or " ✳ Claude ",
    title_pos = "center",
    footer = " q or Esc closes · y copies ",
    footer_pos = "center",
    -- Above the pane, even shown over the terminal.
    zindex = 100,
  }
  local win = api.nvim_open_win(buf, true, config)
  for option, value in pairs { wrap = true, linebreak = true, cursorline = true } do
    vim.wo[win][option] = value
  end
  -- As tall as the notes need, up to most of the editor.
  config.height = math.max(1, math.min(most, api.nvim_win_text_height(win, {}).all))
  config.row = math.max(0, math.floor((vim.o.lines - config.height) / 2) - 1)
  api.nvim_win_set_config(win, config)

  local function back()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    if not api.nvim_win_is_valid(from_win) or api.nvim_win_get_buf(from_win) ~= from_buf then
      return
    end
    api.nvim_set_current_win(from_win)
    pcall(api.nvim_win_set_cursor, from_win, cursor)
    if typing then
      local line = api.nvim_buf_get_lines(from_buf, cursor[1] - 1, cursor[1], false)[1] or ""
      -- At the end of the line, normal mode can't put the cursor where typing was.
      vim.cmd(cursor[2] >= #line and "startinsert!" or "startinsert")
    end
  end
  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true })
  end
  map("n", "q", back)
  map("n", "<Esc>", back)
  map({ "n", "x" }, "y", '"+y')
  -- Leaving it some other way (a click elsewhere) closes it there.
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if api.nvim_win_is_valid(win) then
          api.nvim_win_close(win, true)
        end
      end)
    end,
  })
end

-- The terminal's keys on a notes buffer, with Ctrl+Shift+h/j/k/l moving or sizing the
-- pane rather than the terminal.
set_up_buffer = function(buf, editable)
  floatterm().map_keys(buf, { "n" })
  local modes = editable and { "n", "i" } or { "n" }
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
  end
  for _, keys in ipairs(SIDES) do
    for i = 1, 2 do
      map(modes, keys[i], function() side_key(keys[3]) end, "notes move to the " .. keys[3] .. " (or resize on that side)")
    end
  end
  map(modes, "<C-S-e>", M.toggle_focus, "notes back to the terminal")
  -- Normal mode only: in insert mode Ctrl+\ starts Neovim's own Ctrl+\ Ctrl+n and
  -- Ctrl+\ Ctrl+o.
  map("n", "<C-\\>", M.hide_float, "terminal toggle floating term")
  map("n", "<Esc>", on_escape, "notes back to the terminal (shown over it)")
  if editable then
    map(modes, "<C-S-o>", M.read_claude, "notes read all of Claude's notes")
    api.nvim_create_autocmd({ "BufLeave", "FocusLost", "BufHidden", "WinLeave" }, {
      buffer = buf,
      callback = function(args)
        save(args.buf)
      end,
    })
  end
end

-- Puts lines at the end of a tab's notes, switching them on if they're off, and saves.
-- With `gap`, a blank line first unless the notes already end with one.
local function append(record, lines, gap)
  if not record.notes_on then
    M.set(record.buf, true)
  end
  local buf = mine_buf(record)
  local last = api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
  if gap and vim.trim(last) ~= "" then
    table.insert(lines, 1, "")
  end
  if api.nvim_buf_line_count(buf) == 1 and last == "" then
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end
  save(buf)
  for _, win in ipairs { pane.mine } do
    if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
      api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
    end
  end
end

-- `### HH:MM · source` and the text in a fenced block, long enough not to be closed by
-- a fence inside the text.
local function block(source, text, lang)
  local body = vim.split(text, "\n", { plain = true })
  if #body > 1 and body[#body] == "" then
    table.remove(body)
  end
  local fence = "```"
  while text:find(fence, 1, true) do
    fence = fence .. "`"
  end
  local lines = { "### " .. os.date "%H:%M" .. " · " .. source, fence .. (lang or "") }
  vim.list_extend(lines, body)
  table.insert(lines, fence)
  return lines
end

local function leave_visual()
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

-- Where a terminal selection came from: a Claude tab's task, else what the shell is
-- running (or last ran), else the tab's name.
local function terminal_source(record)
  local tabbar = require "floatterm.tabbar"
  if record.kind == "claude" then
    return tabbar.summary(record) or floatterm().name(record)
  end
  if record.command and tabbar.is_running(record) then
    return record.command
  end
  return record.last_command or floatterm().name(record)
end

-- Y in a terminal tab: the selection, with lines the terminal only wrapped joined.
function M.capture_terminal()
  local record = floatterm().record(api.nvim_get_current_buf())
  if not record then
    return
  end
  local text = floatterm().unwrapped_selection()
  leave_visual()
  append(record, block(terminal_source(record), text), true)
end

local function relative(path)
  if path == "" then
    return "[No Name]"
  end
  local base = folder() .. "/"
  local real = vim.uv.fs_realpath(path) or path
  if real:sub(1, #base) == base then
    return real:sub(#base + 1)
  end
  return vim.fn.fnamemodify(path, ":~:.")
end

-- <leader>o y: the selection in code (or the line, outside visual mode) into the notes
-- of the tab the float last showed. In a terminal tab it's Y's job.
function M.capture()
  local ft = floatterm()
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  if ft.record(api.nvim_get_current_buf()) then
    if visual then
      M.capture_terminal()
    else
      vim.notify("floatterm: select text first (Ctrl+x, then v), then Y", vim.log.levels.INFO)
    end
    return
  end
  if in_pane(api.nvim_get_current_win()) then
    return
  end
  local record = ft.record(ft.current_buf() or -1)
  if not record then
    vim.notify("floatterm: no terminal tab to add notes to", vim.log.levels.INFO)
    return
  end

  local from, to = vim.fn.getpos(visual and "v" or "."), vim.fn.getpos "."
  local text = visual and table.concat(vim.fn.getregion(from, to, { type = mode }), "\n") or api.nvim_get_current_line()
  local first, last = math.min(from[2], to[2]), math.max(from[2], to[2])
  if visual then
    leave_visual()
  end
  local source = relative(api.nvim_buf_get_name(0)) .. ":" .. first .. (last ~= first and ("-" .. last) or "")
  local lang = vim.bo.filetype ~= "" and vim.bo.filetype or nil
  append(record, block(source, text, lang), true)
  vim.notify("Added to notes for " .. ft.name(record))
end

-- <leader>o a: one line, `- HH:MM text`.
function M.add_note()
  local record = target_record()
  if not record then
    vim.notify("floatterm: no terminal tab for notes", vim.log.levels.INFO)
    return
  end
  local buf = record.buf
  vim.ui.input({ prompt = "Note for " .. floatterm().name(record) .. ": " }, function(input)
    input = input and vim.trim(input) or ""
    local now = floatterm().record(buf)
    if input == "" or not now then
      return
    end
    local mine = mine_buf(now)
    local last = api.nvim_buf_get_lines(mine, -2, -1, false)[1] or ""
    -- Notes in a row make one list.
    append(now, { "- " .. os.date "%H:%M" .. " " .. input }, not last:match "^%- %d%d:%d%d ")
  end)
end

-- Deletes a note's file of yours when it holds nothing but the heading it was made with
-- and no other tab has it. Kept when Claude has written some, so the picker still finds
-- them. `name` is the tab's name, for a note made before this nvim started: the heading
-- it would have been made with.
local function delete_if_empty(note_id, closing_buf, name)
  for _, record in ipairs(floatterm().tabs()) do
    if record.note_id == note_id and record.buf ~= closing_buf then
      return
    end
  end
  local paths = paths_for(note_id)
  if vim.uv.fs_stat(paths.claude) then
    return
  end
  local buf = vim.fn.bufnr(paths.mine)
  local lines
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    save(buf)
    lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    lines = read_lines(paths.mine)
  end
  if not lines then
    return
  end
  -- Blank lines at the end are left by going into the notes (an empty line to type on).
  -- A file with nothing left in it at all counts as empty too.
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  local heading = created[note_id] or (name and ("# " .. name))
  if #lines > 1 or (#lines == 1 and lines[1] ~= heading) then
    return
  end
  if buf ~= -1 then
    if pane.mine and api.nvim_win_is_valid(pane.mine) and api.nvim_win_get_buf(pane.mine) == buf then
      close_windows()
    end
    configured[buf] = nil
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  os.remove(paths.mine)
  created[note_id] = nil
end

-- Gives the tab `buf` the notes `note_id` and shows them.
function M.attach(buf, note_id)
  local ft = floatterm()
  local record = ft.record(buf)
  if not record then
    return
  end
  local old = record.note_id
  if old and old ~= note_id then
    save(vim.fn.bufnr(paths_for(old).mine))
  end
  ft.update(buf, { note_id = note_id, notes_on = true })
  if old and old ~= note_id then
    delete_if_empty(old, nil, ft.name(record))
  end
end

-- Deletes a note, both files, and takes it off any tab that has it.
function M.delete(note_id)
  local ft = floatterm()
  for _, record in ipairs(ft.tabs()) do
    if record.note_id == note_id then
      ft.update(record.buf, { note_id = vim.NIL, notes_on = vim.NIL })
    end
  end
  local paths = paths_for(note_id)
  for _, buf in ipairs { vim.fn.bufnr(paths.mine), claude_bufs[note_id] or -1 } do
    if buf ~= -1 and api.nvim_buf_is_valid(buf) then
      configured[buf] = nil
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  claude_bufs[note_id] = nil
  os.remove(paths.mine)
  os.remove(paths.claude)
end

local function size_text(bytes)
  if bytes < 1024 then
    return bytes .. " B"
  end
  return string.format("%.1f KB", bytes / 1024)
end

-- Every note of yours in the folder, newest first: { id, path, title, mtime, size, tab }.
function M.list()
  local dir = M.dir()
  local found = {}
  if not vim.uv.fs_stat(dir) then
    return found
  end
  local open = {}
  for _, record in ipairs(floatterm().tabs()) do
    if record.note_id then
      open[record.note_id] = floatterm().name(record)
    end
  end
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match "%.md$" and not name:match "%.claude%.md$" then
      local id = name:gsub("%.md$", "")
      local path = dir .. "/" .. name
      local stat = vim.uv.fs_stat(path)
      local title = id
      for _, line in ipairs(read_lines(path) or {}) do
        local heading = line:match "^#%s+(.+)"
        if heading then
          title = heading
          break
        end
      end
      table.insert(found, {
        id = id,
        path = path,
        title = title,
        mtime = stat and stat.mtime.sec or 0,
        size = stat and stat.size or 0,
        tab = open[id],
      })
    end
  end
  table.sort(found, function(a, b)
    return a.mtime > b.mtime
  end)
  return found
end

-- <leader>o o: notes in this folder. Enter gives them to the tab the float last
-- showed; Ctrl+d deletes, after asking.
function M.pick()
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("floatterm: notes need telescope", vim.log.levels.WARN)
    return
  end
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local entry_display = require "telescope.pickers.entry_display"

  local notes = M.list()
  if #notes == 0 then
    vim.notify("floatterm: no notes in " .. vim.fn.fnamemodify(folder(), ":~"), vim.log.levels.INFO)
    return
  end
  local displayer = entry_display.create {
    separator = "  ",
    items = { { width = 32 }, { width = 16 }, { width = 8 }, { remaining = true } },
  }
  pickers
    .new({}, {
      prompt_title = "Notes",
      finder = finders.new_table {
        results = notes,
        entry_maker = function(note)
          return {
            value = note,
            path = note.path,
            ordinal = note.title .. " " .. note.id,
            display = function()
              return displayer {
                note.title,
                { os.date("%Y-%m-%d %H:%M", note.mtime), "Comment" },
                { size_text(note.size), "Comment" },
                note.tab and { "● open in " .. note.tab, "FloatTermWorking" } or "",
              }
            end,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = conf.file_previewer {},
      attach_mappings = function(prompt_buf, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_buf)
          local buf = floatterm().current_buf()
          if not (entry and buf) then
            vim.notify("floatterm: no terminal tab to give the notes to", vim.log.levels.INFO)
            return
          end
          M.attach(buf, entry.value.id)
        end)
        map({ "i", "n" }, "<C-d>", function()
          local entry = action_state.get_selected_entry()
          if not entry then
            return
          end
          actions.close(prompt_buf)
          local note = entry.value
          local prompt = "Delete the notes " .. note.title .. "?"
          vim.ui.select({ "Delete them", "Keep them" }, { prompt = prompt }, function(choice)
            if choice == "Delete them" then
              M.delete(note.id)
            end
            vim.schedule(M.pick)
          end)
        end)
        return true
      end,
    })
    :find()
end

-- The pane's windows and what they show. For tests and debugging.
function M.state()
  return vim.deepcopy(pane)
end

-- A float other than the terminal and its tab bar: a prompt, a picker, a popup.
local function is_prompt(win)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative == "" then
    return false
  end
  local ft, tabbar = package.loaded["floatterm"], package.loaded["floatterm.tabbar"]
  return not ((ft and win == ft.window()) or (tabbar and win == tabbar.window()))
end

-- Your notes are typed into at the end, on an empty line (added unless the last line
-- already is one).
local function to_fresh_line()
  local win = pane.mine
  if not (win and api.nvim_win_is_valid(win) and api.nvim_get_current_win() == win) then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  local count = api.nvim_buf_line_count(buf)
  if api.nvim_buf_get_lines(buf, count - 1, count, false)[1] ~= "" then
    api.nvim_buf_set_lines(buf, count, count, false, { "" })
    count = count + 1
  end
  api.nvim_win_set_cursor(win, { count, 0 })
  vim.cmd "startinsert"
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true
  folder()

  local group = api.nvim_create_augroup("floatterm_notes", { clear = true })
  local keys_added = false
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FloatTermLayoutChanged", "FloatTermTabsChanged", "FloatTermTabChanged" },
    callback = function(args)
      local ft = package.loaded["floatterm"]
      if args.match == "FloatTermTabsChanged" and ft then
        if not keys_added then
          keys_added = true
          ft.add_tab_key("<C-S-e>", M.toggle_focus, "terminal into the notes and back")
        end
        -- Visual mode, which add_tab_key doesn't map.
        for _, record in ipairs(ft.tabs()) do
          if not tab_keys[record.buf] then
            tab_keys[record.buf] = true
            vim.keymap.set("x", "Y", M.capture_terminal, { buffer = record.buf, desc = "terminal selection to notes" })
          end
        end
      end
      if args.match == "FloatTermLayoutChanged" and not args.data.open then
        close()
        return
      end
      if args.match == "FloatTermTabChanged" then
        -- The tab bar's once-a-second title and command updates don't change the pane.
        local relevant = false
        for _, field in ipairs(args.data.fields or {}) do
          relevant = relevant or field == "notes_on" or field == "note_id" or field == "kind" or field == "label"
        end
        if not relevant then
          return
        end
      end
      schedule_redraw()
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FloatTermClaudeNotesChanged",
    callback = function(args)
      local note_id = args.data and args.data.note_id
      if note_id then
        load_claude(note_id)
      end
      schedule_redraw()
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      left = api.nvim_get_current_win()
    end,
  })
  -- Moving into the split's empty notes window (Ctrl+w, a click) lands in the notes.
  -- Going into yours from outside the pane starts typing on an empty line at the end.
  -- A prompt, picker or popup opened from yours is a detour that comes back to where
  -- you were; anywhere else, notes shown over the terminal are put away.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local ft = package.loaded["floatterm"]
      if not ft then
        return
      end
      local win = api.nvim_get_current_win()
      local held = ft.layout().notes_window
      if held and win == held then
        vim.schedule(function()
          if pane.mine and api.nvim_win_is_valid(pane.mine) then
            api.nvim_set_current_win(pane.mine)
          end
        end)
      elseif win == pane.mine then
        local returning = pane.away or left == pane.claude
        pane.away = false
        if not returning then
          vim.schedule(to_fresh_line)
        end
      elseif in_pane(win) then
        return
      elseif is_prompt(win) then
        if left == pane.mine then
          pane.away = true
        end
      elseif pane.overlay and pane.away then
        -- The prompt closed into the terminal rather than back into the notes.
        vim.schedule(function()
          local now = api.nvim_get_current_win()
          if pane.overlay and pane.mine and api.nvim_win_is_valid(pane.mine) and not in_pane(now) and not is_prompt(now) then
            api.nvim_set_current_win(pane.mine)
          end
        end)
      elseif pane.overlay then
        vim.schedule(function()
          if pane.overlay and not in_pane(api.nvim_get_current_win()) then
            pane.overlay = false
            M.redraw()
          end
        end)
      else
        pane.away = false
      end
    end,
  })
  -- :q in either part closes the whole pane, and where it has a box of its own beside
  -- the terminal, draws it again whole.
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed == pane.mine then
        pane.mine = nil
      elseif closed == pane.claude then
        pane.claude = nil
      else
        return
      end
      if closing then
        return
      end
      vim.schedule(function()
        if pane.overlay then
          pane.overlay = false
          close_windows()
        else
          close_windows()
          M.redraw()
        end
      end)
    end,
  })
  -- Before lua/floatterm drops the tab's record, which happens a moment later.
  api.nvim_create_autocmd("TermClose", {
    group = group,
    callback = function(args)
      local ft = package.loaded["floatterm"]
      local record = ft and ft.record(args.buf)
      tab_keys[args.buf] = nil
      if not (record and record.note_id) then
        return
      end
      if pane.buf == args.buf then
        close()
      end
      delete_if_empty(record.note_id, args.buf, ft.name(record))
    end,
  })
  api.nvim_create_autocmd({ "VimLeavePre", "FocusLost" }, {
    group = group,
    callback = function()
      for buf in pairs(configured) do
        if api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
          save(buf)
        end
      end
    end,
  })
  vim.keymap.set("x", "<leader>oy", M.capture, { desc = "selection to notes" })
end

return M
