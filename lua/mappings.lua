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

-- git
map("n", "<leader>gg", function()
  require("floatterm").new_tab { "lazygit" }
end, { desc = "git lazygit in a terminal tab" })
map("n", "<leader>gs", "<cmd>Telescope git_status<CR>", { desc = "git status" })
map("n", "<leader>gb", "<cmd>Telescope git_branches<CR>", { desc = "git branches (Enter switches)" })
map("n", "<leader>gc", "<cmd>Telescope git_commits<CR>", { desc = "git commits" })
map("n", "<leader>gf", "<cmd>Telescope git_bcommits<CR>", { desc = "git this file's history" })
map("n", "]h", function()
  require("gitsigns").nav_hunk "next"
end, { desc = "git next changed block" })
map("n", "[h", function()
  require("gitsigns").nav_hunk "prev"
end, { desc = "git previous changed block" })
map("n", "<leader>gp", function()
  require("gitsigns").preview_hunk()
end, { desc = "git preview changed block" })
map("n", "<leader>ga", function()
  require("gitsigns").stage_hunk()
end, { desc = "git stage changed block" })
map("v", "<leader>ga", function()
  require("gitsigns").stage_hunk { vim.fn.line ".", vim.fn.line "v" }
end, { desc = "git stage selected lines" })
map("n", "<leader>gr", function()
  require("gitsigns").reset_hunk()
end, { desc = "git undo changed block (u brings it back)" })
map("n", "<leader>gd", function()
  require("gitsigns").diffthis()
end, { desc = "git diff file against last commit" })
map("n", "<leader>gv", function()
  require("gitkeys").toggle_branch_review()
end, { desc = "git review branch against main (again to close)" })
map({ "n", "v" }, "<leader>go", function()
  require("gitkeys").open_on_github()
end, { desc = "git open on GitHub" })

-- tests
map("n", "<leader>tn", function()
  require("testrun").run "nearest"
end, { desc = "test run nearest Pest test" })
map("n", "<leader>tf", function()
  require("testrun").run "file"
end, { desc = "test run this Pest file" })
map("n", "<leader>tl", function()
  require("testrun").run_last()
end, { desc = "test run last again" })

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
