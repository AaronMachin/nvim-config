-- Pinned files through harpoon (harpoon2), kept per project and branch.
--
-- The project is the git root of nvim's working directory, and each branch of it
-- has its own list, so switching branch swaps the pins. Paths are stored relative
-- to the git root, so the same list works whichever folder nvim was opened in.

local M = {}

local configured = false

local function git_root()
  local cwd = vim.uv.cwd()
  return vim.fs.root(cwd, ".git") or cwd
end

-- The branch from .git/HEAD, or "detached" when HEAD is a commit. A detached HEAD
-- moves with every commit and rebase step, so keying on the commit would start an
-- empty list each time. Read straight from the file because harpoon asks for the key
-- on every buffer switch, and a git call each time would be noticeable. In a
-- worktree .git is a file naming the real one.
local function branch(root)
  local git = root .. "/.git"
  local stat = vim.uv.fs_stat(git)
  if stat and stat.type == "file" then
    local pointer = vim.fn.readfile(git, "", 1)[1] or ""
    local gitdir = pointer:match "^gitdir:%s*(.-)%s*$"
    if not gitdir then
      return "unknown"
    end
    git = gitdir:sub(1, 1) == "/" and gitdir or (root .. "/" .. gitdir)
  end

  local ok, lines = pcall(vim.fn.readfile, git .. "/HEAD", "", 1)
  local head = ok and lines[1] or ""
  return head:match "^ref: refs/heads/(.+)$" or "detached"
end

local function key()
  local root = git_root()
  return root .. ":" .. branch(root)
end

local function harpoon()
  local h = require "harpoon"
  if configured then
    return h
  end

  local default_select = require("harpoon.config").get_default_config().default.select
  h:setup {
    settings = { key = key, save_on_toggle = true, sync_on_ui_close = true },
    default = {
      get_root_dir = git_root,
      -- Harpoon opens the stored path as given, which is relative to the git root
      -- and not necessarily to the working directory.
      select = function(item, list, options)
        if not item then
          return
        end
        local absolute = vim.deepcopy(item)
        if absolute.value:sub(1, 1) ~= "/" then
          absolute.value = git_root() .. "/" .. absolute.value
        end
        default_select(absolute, list, options)
        item.context = absolute.context
      end,
    },
  }
  configured = true
  return h
end

-- Harpoon loads one key's file when it starts and keeps the rest in memory, so a
-- branch switched to later would show no pins, and the next add would save over
-- that branch's file with just the new one. Loading the file first stops that.
local function list()
  local h = harpoon()
  local current = key()
  if h.data._data[current] == nil then
    local ok, stored = pcall(require("harpoon.data").test.read_data, h.config)
    if ok and stored[current] then
      h.data._data[current] = stored[current]
    end
  end
  return h:list()
end

function M.add()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    vim.notify("pins: not a file", vim.log.levels.WARN)
    return
  end
  local pins = list()
  local item = pins.config.create_list_item(pins.config)
  local name = vim.fn.fnamemodify(file, ":t")
  local _, index = pins:get_by_value(item.value)
  if index then
    vim.notify("pins: " .. name .. " is already pinned as " .. index)
    return
  end
  pins:add(item)
  _, index = pins:get_by_value(item.value)
  vim.notify("pins: pinned " .. name .. " as " .. index)
end

function M.menu()
  harpoon().ui:toggle_quick_menu(list(), { title = " Pins · " .. branch(git_root()) .. " " })
end

function M.jump(n)
  local pins = list()
  if not pins:get(n) then
    vim.notify("pins: nothing pinned at " .. n, vim.log.levels.WARN)
    return
  end
  pins:select(n)
end

return M
