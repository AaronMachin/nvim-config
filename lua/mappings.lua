require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

local function toggle_float_term()
  require("floatterm").toggle()
end

map("n", "<leader>tt", toggle_float_term, { desc = "terminal toggle floating term" })
-- <leader>tt can't close it from inside, where space has to reach the shell
map({ "n", "t" }, "<C-\\>", toggle_float_term, { desc = "terminal toggle floating term" })
-- NvChad's own float would be a second, tabless terminal
map({ "n", "t" }, "<A-i>", toggle_float_term, { desc = "terminal toggle floating term" })

map("n", "<leader>fw", function()
  require("grepmask").live_grep()
end, { desc = "telescope live grep with file mask" })
map({ "n", "v" }, "<leader>fW", function()
  require("grepmask").grep_word()
end, { desc = "telescope grep word under cursor or selection" })
map("n", "<leader>fr", "<cmd>Telescope resume<CR>", { desc = "telescope reopen last picker" })

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
