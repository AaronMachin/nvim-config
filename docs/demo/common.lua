-- Shared by the seeds: keys the recorder can send for ones it can't (it has no
-- Ctrl+Shift), and a stand-in Claude tab.
local M = {}

-- The recorder can't send Ctrl+Shift or Alt keys nvim reads, so for the GIFs:
-- Ctrl+G opens and hides the float (Ctrl+\ or Alt+i), Ctrl+B goes into the tab bar
-- (Ctrl+Shift+b) and Ctrl+N goes to the next tab (Ctrl+Shift+n).
function M.keys()
  local ft = require "floatterm"
  vim.keymap.set({ "n", "t" }, "<C-g>", function()
    ft.toggle()
  end)
  vim.keymap.set({ "n", "t" }, "<C-b>", function()
    require("floatterm.tabbar").enter()
  end)
  vim.keymap.set({ "n", "t" }, "<C-n>", function()
    ft.next_tab()
  end)
end

-- A tab that looks like a Claude session: `lines` printed, a status and a title.
function M.claude_tab(label, fields, lines)
  local ft = require "floatterm"
  local script = "printf '%s\\n' " .. table.concat(vim.tbl_map(vim.fn.shellescape, lines), " ") .. "; sleep 3600"
  local _, buf = ft.new_tab({ "sh", "-c", script }, { kind = "claude", label = label, show = false })
  ft.update(buf, fields)
  return buf
end

return M
