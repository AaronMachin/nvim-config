require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

map("n", "<leader>tt", function()
  require("nvchad.term").toggle { pos = "float", id = "floatTerm" }
end, { desc = "terminal toggle floating term" })

map("n", "<leader>fw", function()
  require("grepmask").live_grep()
end, { desc = "telescope live grep with file mask" })

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
