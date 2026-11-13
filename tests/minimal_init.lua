-- Loaded with -u by tests/run.sh for every spec file. It doesn't run init.lua (lazy.nvim
-- and base46's cache would want the real data folder); it puts this config's lua/ and
-- the plugins the modules use on the runtimepath, straight from the real lazy folder,
-- and points every place the modules write at a throwaway folder.

local root = vim.env.NVIM_TEST_ROOT
assert(root and root ~= "", "run the tests with `make test` (tests/run.sh sets up the environment)")

-- Never against the real data, state or cache folders.
for _, what in ipairs { "data", "state", "cache" } do
  local path = vim.fn.stdpath(what)
  assert(path:sub(1, #root) == root, what .. " folder " .. path .. " isn't under " .. root)
  -- They exist in a real install (harpoon only makes its own folder inside data).
  vim.fn.mkdir(path, "p")
end

local config = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local lazy = vim.env.NVIM_TEST_LAZY or (vim.env.HOME .. "/.local/share/nvim/lazy")

vim.opt.rtp:prepend(config)
-- Specs require "test_helpers" (telescope ships a lua/tests/helpers of its own).
package.preload["test_helpers"] = function()
  return dofile(config .. "/tests/helpers.lua")
end
for _, name in ipairs { "plenary.nvim", "telescope.nvim", "ui", "NvChad", "which-key.nvim", "harpoon" } do
  vim.opt.rtp:append(lazy .. "/" .. name)
end
vim.cmd "runtime plugin/plenary.vim"

vim.g.mapleader = " "
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.lines = 50
vim.o.columns = 200
-- Terminal tabs opened with the default shell run `sleep` (see tests/run.sh).
vim.o.shell = root .. "/bin/fakesh"

-- Per nvim process, as spec files run side by side.
local proc = root .. "/proc-" .. vim.fn.getpid()
vim.g.nvim_test_proc = proc
-- A child nvim started by a spec (H.child) gives its own with --cmd, and keeps the
-- folder it was started in.
vim.g.floatterm_placement_dir = vim.g.floatterm_placement_dir or (proc .. "/placement")
vim.g.floatterm_tabs_dir = vim.g.floatterm_tabs_dir or (proc .. "/tabs")
-- Haiku picking Claude tabs' emoji would run claude; tests/emoji_spec.lua turns it on
-- with a fake one.
if vim.g.floatterm_emoji_picker == nil then
  vim.g.floatterm_emoji_picker = false
end
if not vim.env.NVIM_TEST_CHILD then
  local start = proc .. "/start"
  vim.fn.mkdir(start, "p")
  vim.cmd.cd(vim.fn.fnameescape(start))
end

-- The settings file, before any module reads it.
local ok, settings = pcall(require, "floatterm.settings")
if ok then
  settings.path = proc .. "/floatterm-settings.json"
  settings.reload()
end
