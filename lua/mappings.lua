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

map("n", "<leader>gj", function()
  require("gitkeys").open_ticket()
end, { desc = "git open branch's Jira ticket" })

-- Claude
local function agent(fn)
  return function()
    require("agent")[fn]()
  end
end
map("n", "<leader>ac", function()
  require("agent").start(vim.fs.root(0, ".git") or vim.uv.cwd())
end, { desc = "claude open or focus for this project" })
map({ "n", "v" }, "<leader>as", agent "send_selection", { desc = "claude send selection or file" })
map("n", "<leader>aq", agent "send_quickfix", { desc = "claude send quickfix list" })
map("n", "<leader>at", agent "send_last_test", { desc = "claude send last test output" })
map("v", "<leader>ae", agent "explain", { desc = "claude explain selection" })
map("n", "<leader>ar", agent "review", { desc = "claude review changes since it started" })
map("n", "<leader>ay", "<cmd>ClaudeCodeDiffAccept<CR>", { desc = "claude accept diff" })
map("n", "<leader>an", "<cmd>ClaudeCodeDiffDeny<CR>", { desc = "claude reject diff" })
map("n", "<leader>gm", agent "commit_message", { desc = "git commit message from Claude" })

-- Names for the leader groups, so the which-key panel reads "a → claude" rather than
-- a bare letter. <leader>o (terminal) is named in lua/floatterm/menu.
pcall(function()
  require("which-key").add {
    { "<leader>a", group = "claude" },
    { "<leader>d", group = "debug" },
    { "<leader>f", group = "find" },
    { "<leader>g", group = "git" },
    { "<leader>l", group = "laravel" },
    { "<leader>p", group = "pins and phpstan" },
    { "<leader>s", group = "database" },
    { "<leader>t", group = "terminal and tests" },
    { "<leader>w", group = "worktrees" },
  }
end)

-- the floating terminal's tab bar, Claude bookmark and settings page
require("floatterm.tabbar").setup()
require("floatterm.bookmark").setup()
require("floatterm.config_page").setup()
require("floatterm.menu").setup()
require("floatterm.notes").setup()
map("n", "<leader>ab", function()
  require("floatterm.bookmark").toggle()
end, { desc = "claude show or hide the sessions bookmark" })
map("n", "<leader>aa", function()
  require("floatterm.overview").pick()
end, { desc = "claude every Claude tab, by state" })

-- worktrees (setup saves a session on quit, so it runs at startup)
require("worktrees").setup()
map("n", "<leader>ww", function()
  require("worktrees").pick()
end, { desc = "worktrees pick (Enter moves nvim, C-a Claude, C-s main)" })
map("n", "<leader>wn", function()
  require("worktrees").create()
end, { desc = "worktrees new for a ticket" })

-- pinned files
map("n", "<leader>pa", function()
  require("pins").add()
end, { desc = "pins pin this file" })
map("n", "<leader>pp", function()
  require("pins").menu()
end, { desc = "pins menu" })
for i = 1, 4 do
  map("n", "<leader>" .. i, function()
    require("pins").jump(i)
  end, { desc = "pins jump to " .. i })
end

-- Laravel, PHPStan and the database
map("n", "<leader>lr", function()
  require("laravel").routes()
end, { desc = "laravel routes" })
map("n", "<leader>lj", function()
  require("laravel").related()
end, { desc = "laravel related files" })
map("n", "<leader>ps", function()
  require("phpstan").run()
end, { desc = "phpstan run through Sail" })
map("n", "<leader>sq", function()
  require("dbkeys").open()
end, { desc = "database open DBUI on project db" })

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
