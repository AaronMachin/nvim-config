-- Floating terminal with tabs.
--
-- One float window shows one of several shell buffers at a time. The border title
-- lists the tabs and marks the one showing. Hiding the float leaves every shell
-- running; it reopens on the tab last shown. A tab closes when its shell exits.

local M = {}

local api = vim.api

local bufs = {}
local current = 0
local win = nil

local function win_is_open()
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function title()
  local labels = {}
  for i = 1, #bufs do
    labels[i] = i == current and ("[" .. i .. "]") or tostring(i)
  end
  return " " .. table.concat(labels, " │ ") .. " "
end

local HEIGHT = 0.9

-- Full width, the bottom 90% of the editor, sitting just above the statusline.
local function float_config()
  local available = vim.o.lines - vim.o.cmdheight - 1
  -- The border adds a row above and below, and a column either side.
  local outer_height = math.floor(available * HEIGHT)

  return {
    relative = "editor",
    border = require("nvconfig").term.float.border,
    width = vim.o.columns - 2,
    height = outer_height - 2,
    row = available - outer_height,
    col = 0,
    title = title(),
    title_pos = "center",
  }
end

-- Puts the current tab's buffer in the float, opening the float if it's hidden.
local function show_current()
  local buf = bufs[current]

  if win_is_open() then
    api.nvim_win_set_buf(win, buf)
    api.nvim_win_set_config(win, { title = title(), title_pos = "center" })
  else
    win = api.nvim_open_win(buf, true, float_config())
    for option, value in pairs(require("nvconfig").term.winopts) do
      vim.wo[win][option] = value
    end
  end

  api.nvim_set_current_win(win)
  vim.cmd "startinsert"
end

local function map_tab_keys(buf)
  local opts = { buffer = buf }
  vim.keymap.set({ "n", "t" }, "<C-t>", M.new_tab, vim.tbl_extend("force", opts, { desc = "terminal new tab" }))
  vim.keymap.set(
    { "n", "t" },
    "<C-S-\\>",
    M.next_tab,
    vim.tbl_extend("force", opts, { desc = "terminal next tab" })
  )
end

function M.new_tab()
  local buf = api.nvim_create_buf(false, true)
  table.insert(bufs, buf)
  current = #bufs

  show_current()
  api.nvim_buf_call(buf, function()
    -- A bare { shell } is deleted by Neovim's own TermClose handler before ours
    -- runs, taking the float with it. -i is what the shell would be anyway.
    vim.fn.termopen { vim.o.shell, "-i" }
  end)
  map_tab_keys(buf)
  -- termopen renames the buffer, so the title is set again after it.
  show_current()
end

function M.next_tab()
  if #bufs < 2 then
    return
  end

  current = current % #bufs + 1
  show_current()
end

function M.toggle()
  if win_is_open() then
    api.nvim_win_close(win, true)
    win = nil
    return
  end

  if #bufs == 0 then
    M.new_tab()
  else
    show_current()
  end
end

api.nvim_create_autocmd("TermClose", {
  callback = function(args)
    local index = nil
    for i, buf in ipairs(bufs) do
      if buf == args.buf then
        index = i
      end
    end
    if not index then
      return
    end

    vim.schedule(function()
      table.remove(bufs, index)

      if #bufs == 0 then
        current = 0
        if win_is_open() then
          api.nvim_win_close(win, true)
        end
        win = nil
      else
        if current >= index then
          current = math.max(current - 1, 1)
        end
        -- Swap the window onto another tab first; deleting the buffer it shows
        -- would close the float.
        if win_is_open() then
          show_current()
        end
      end

      if api.nvim_buf_is_valid(args.buf) then
        api.nvim_buf_delete(args.buf, { force = true })
      end
    end)
  end,
})

return M
