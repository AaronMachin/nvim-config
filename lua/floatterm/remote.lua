-- What Claude (or anything) running in a floatterm tab can ask this nvim to do, over
-- $NVIM, through the scripts in bin/ (see the floatterm skill, claude/skills/floatterm):
--
--   bin/floatterm-offer <file>   M.offer: offers a file to look at. The tab gets 📄 in
--                                the bar, and a pop-up shows when you're in that tab
--                                (straight away if you already are): Open in nvim,
--                                Preview here, Copy full path, Don't open. What you
--                                picked goes back to the script (M.result). Offers
--                                aren't saved: they don't outlive nvim.
--   bin/floatterm-tab new ...    M.open_tab: a new tab, under the one asking or beside
--                                it, a shell or a Claude started with a prompt, opened
--                                in the background so nothing takes the focus.
--
-- Nothing here opens a file in nvim or moves the focus unless you pick it in the
-- pop-up.

local M = {}

local api = vim.api

local function floatterm()
  return require "floatterm"
end

local function find_tab(tab_id)
  tab_id = tonumber(tab_id)
  for _, record in ipairs(floatterm().tabs()) do
    if record.id == tab_id and record.kind ~= "group" then
      return record
    end
  end
  return nil
end

-- Offers waiting, by tab buffer: lists of { id, path }. What was picked, by offer id.
local waiting = {}
local results = {}
local next_offer = 1

-- How long after the pop-up shows before its keys work, so a key you were already
-- typing in the tab doesn't pick something.
M.ARM_MS = 400

local popup = nil -- { win, buf, offer, record_buf }

-- Offers waiting on the tab `record`, oldest first.
function M.waiting(record)
  return record and waiting[record.buf] or {}
end

local function redraw_bar()
  local tabbar = package.loaded["floatterm.tabbar"]
  if tabbar then
    vim.schedule(tabbar.redraw)
  end
end

local function back_to_terminal()
  local win = floatterm().window()
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
    vim.cmd "startinsert"
  end
end

local show_next

local function close_popup()
  if popup and api.nvim_win_is_valid(popup.win) then
    api.nvim_win_close(popup.win, true)
  end
  popup = nil
end

-- Takes `offer` off its tab's list with `outcome` for the script to read.
local function finish(record_buf, offer, outcome)
  local list = waiting[record_buf] or {}
  for i, other in ipairs(list) do
    if other.id == offer.id then
      table.remove(list, i)
      break
    end
  end
  if #list == 0 then
    waiting[record_buf] = nil
  end
  results[offer.id] = outcome
  redraw_bar()
end

-- The file read-only in a large float over the terminal; q or Esc closes it.
local function preview(path)
  local lines = vim.fn.readfile(path)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local filetype = vim.filetype.match { filename = path, buf = buf }
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  local width = math.max(20, math.min(100, vim.o.columns - 6))
  local height = math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.8)))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. vim.fn.fnamemodify(path, ":t") .. " ",
    title_pos = "center",
    footer = " q closes · y copies ",
    footer_pos = "center",
    zindex = 100,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    back_to_terminal()
    vim.schedule(show_next)
  end
  for _, lhs in ipairs { "q", "<Esc>" } do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
  end
  vim.keymap.set({ "n", "x" }, "y", '"+y', { buffer = buf, nowait = true })
end

local CHOICES = {
  { "o", "Open in nvim" },
  { "p", "Preview here" },
  { "y", "Copy full path" },
  { "n", "Don't open" },
}

local function choose(key)
  if not (popup and popup.armed) then
    return
  end
  local offer, record_buf = popup.offer, popup.record_buf
  close_popup()
  if key == "o" then
    finish(record_buf, offer, "opened")
    floatterm().hide()
    vim.cmd.tabnew(vim.fn.fnameescape(offer.path))
  elseif key == "p" then
    finish(record_buf, offer, "previewed")
    preview(offer.path)
  elseif key == "y" then
    finish(record_buf, offer, "copied")
    vim.fn.setreg("+", offer.path)
    vim.notify("Copied " .. offer.path)
    back_to_terminal()
    vim.schedule(show_next)
  else
    finish(record_buf, offer, "not opened")
    back_to_terminal()
    vim.schedule(show_next)
  end
end

-- Shows the pop-up for the oldest offer on the tab you're in, if there is one and
-- nothing else is showing.
show_next = function()
  if popup and api.nvim_win_is_valid(popup.win) then
    return
  end
  local ft = floatterm()
  local terminal = ft.window()
  if not (terminal and api.nvim_win_is_valid(terminal) and api.nvim_get_current_win() == terminal) then
    return
  end
  local record = ft.record(api.nvim_win_get_buf(terminal))
  local list = record and waiting[record.buf]
  local offer = list and list[1]
  if not offer then
    return
  end

  local lines = {
    " " .. vim.fn.fnamemodify(offer.path, ":t"),
    " " .. vim.fn.fnamemodify(offer.path, ":h"),
    "",
  }
  for _, choice in ipairs(CHOICES) do
    table.insert(lines, "  " .. choice[1] .. "  " .. choice[2])
  end
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
  end
  width = math.min(width, math.max(20, api.nvim_win_get_width(terminal) - 4))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = api.nvim_create_namespace "floatterm_offer"
  api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "Comment" })
  for i = 1, #CHOICES do
    api.nvim_buf_set_extmark(buf, ns, 2 + i, 2, { end_col = 3, hl_group = "FloatTermHintKey" })
  end
  vim.cmd "stopinsert"
  local win = api.nvim_open_win(buf, true, {
    relative = "win",
    win = terminal,
    row = math.max(0, math.floor((api.nvim_win_get_height(terminal) - #lines) / 2) - 1),
    col = math.max(0, math.floor((api.nvim_win_get_width(terminal) - width) / 2) - 1),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " Claude wants you to look at ",
    title_pos = "center",
    footer = #list > 1 and (" %d more waiting "):format(#list - 1) or nil,
    footer_pos = #list > 1 and "center" or nil,
    zindex = 90,
  })
  popup = { win = win, buf = buf, offer = offer, record_buf = record.buf, armed = false }
  local this = popup
  vim.defer_fn(function()
    this.armed = true
  end, M.ARM_MS)
  for _, choice in ipairs(CHOICES) do
    vim.keymap.set("n", choice[1], function()
      choose(choice[1])
    end, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs { "<Esc>", "q" } do
    vim.keymap.set("n", lhs, function()
      choose "n"
    end, { buffer = buf, nowait = true })
  end
  -- Leaving it some other way (a click elsewhere) leaves the offer waiting.
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if popup == this then
          close_popup()
        end
      end)
    end,
  })
end
M.show_next = show_next

-- For bin/floatterm-offer: offers `path` from the tab `tab_id`. Returns the offer's id
-- for M.result, or "" when there's no such tab or file.
function M.offer(tab_id, path)
  local record = find_tab(tab_id)
  path = path and vim.fn.fnamemodify(path, ":p") or ""
  if not record or vim.fn.filereadable(path) ~= 1 then
    return ""
  end
  local id = tostring(next_offer)
  next_offer = next_offer + 1
  waiting[record.buf] = waiting[record.buf] or {}
  table.insert(waiting[record.buf], { id = id, path = path })
  redraw_bar()
  vim.schedule(show_next)
  return id
end

-- What was picked for offer `id`: "opened", "previewed", "copied", "not opened", or ""
-- while it's still waiting.
function M.result(id)
  return results[tostring(id)] or ""
end

-- For bin/floatterm-tab: opens a tab from the tab `tab_id`. opts (a JSON string or a
-- table): under (put it under that tab), claude (a prompt to start Claude with; a shell
-- without), label, cwd (the tab's folder by default). Opened without showing. Returns
-- the new tab's id, or "" when there's no such tab or folder.
function M.open_tab(tab_id, opts)
  if type(opts) == "string" then
    local ok, decoded = pcall(vim.json.decode, opts, { luanil = { object = true } })
    opts = ok and decoded or {}
  end
  opts = opts or {}
  local from = find_tab(tab_id)
  local cwd = opts.cwd and opts.cwd ~= "" and vim.fn.fnamemodify(opts.cwd, ":p"):gsub("/$", "") or (from and from.cwd)
  if not from or vim.fn.isdirectory(cwd or "") ~= 1 then
    return ""
  end
  local ft = floatterm()
  local buf
  if opts.claude and opts.claude ~= "" then
    buf = require("agent").open(cwd, { argv = { "claude", opts.claude }, label = opts.label, show = false })
  else
    buf = select(2, ft.new_tab(nil, { cwd = cwd, label = opts.label, show = false }))
  end
  local groups = require "floatterm.groups"
  if opts.under then
    groups.set_parent(buf, from.buf)
  else
    -- Beside the tab asking, among its own siblings.
    if from.parent_uid then
      groups.set_parent(buf, groups.parent(from).buf)
    end
    local tabs = ft.tabs()
    local at, from_at
    for i, record in ipairs(tabs) do
      if record.buf == buf then
        at = i
      elseif record.buf == from.buf then
        from_at = i
      end
    end
    if at and from_at and at > from_at + 1 then
      local steps = 0
      for i = from_at + 1, at - 1 do
        if tabs[i].parent_uid == ft.record(buf).parent_uid then
          steps = steps + 1
        end
      end
      if steps > 0 then
        ft.move_tab(buf, -steps)
      end
    end
  end
  local record = ft.record(buf)
  return record and tostring(record.id) or ""
end

local set_up = false

function M.setup()
  if set_up then
    return
  end
  set_up = true
  local group = api.nvim_create_augroup("floatterm_remote", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "FloatTermTabsChanged", "FloatTermLayoutChanged" },
    callback = function()
      vim.schedule(show_next)
    end,
  })
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      vim.schedule(show_next)
    end,
  })
  -- A closed tab's offers go with it.
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FloatTermTabsChanged",
    callback = function()
      for buf, list in pairs(waiting) do
        if not floatterm().record(buf) then
          for _, offer in ipairs(list) do
            results[offer.id] = "not opened"
          end
          waiting[buf] = nil
        end
      end
    end,
  })
end

return M
