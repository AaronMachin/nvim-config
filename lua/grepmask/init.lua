-- Live grep with IntelliJ-style file masks.
--
-- A mask is a comma-separated list of wildcards ("*.php, !*Test.php, !vendor/**"),
-- passed to ripgrep as --glob. Each project (git root, else cwd) remembers its own
-- active mask, and every mask used goes into a recent list shared by all projects.
-- Both are kept in stdpath("data")/grepmask.json so they survive restarts.

local M = {}

local MAX_RECENT = 20
local state_path = vim.fn.stdpath "data" .. "/grepmask.json"

local function read_state()
  local state = { recent = {}, active = {} }
  local file = io.open(state_path, "r")
  if not file then
    return state
  end

  local ok, decoded = pcall(vim.json.decode, file:read "*a")
  file:close()
  if ok and type(decoded) == "table" then
    state.recent = type(decoded.recent) == "table" and decoded.recent or {}
    state.active = type(decoded.active) == "table" and decoded.active or {}
  end

  return state
end

local function write_state(state)
  local file = io.open(state_path, "w")
  if not file then
    vim.notify("grepmask: could not write " .. state_path, vim.log.levels.WARN)
    return
  end

  -- An empty `active` table would encode as [], which is fine to read back.
  file:write(vim.json.encode(state))
  file:close()
end

local function project_root()
  local cwd = vim.uv.cwd()
  return vim.fs.root(cwd, ".git") or cwd
end

local function parse_mask(mask)
  local globs = {}
  for entry in (mask or ""):gmatch "[^,]+" do
    entry = vim.trim(entry)
    if entry ~= "" then
      table.insert(globs, entry)
    end
  end
  return globs
end

function M.active_mask()
  return read_state().active[project_root()]
end

function M.set_mask(mask)
  local state = read_state()
  local root = project_root()
  mask = table.concat(parse_mask(mask), ", ")

  if mask == "" then
    state.active[root] = nil
    write_state(state)
    return
  end

  state.active[root] = mask
  state.recent = vim.tbl_filter(function(recent)
    return recent ~= mask
  end, state.recent)
  table.insert(state.recent, 1, mask)
  while #state.recent > MAX_RECENT do
    table.remove(state.recent)
  end

  write_state(state)
end

local function edit_mask(prompt_bufnr)
  local text = require("telescope.actions.state").get_current_line()
  require("telescope.actions").close(prompt_bufnr)

  vim.schedule(function()
    vim.ui.input({ prompt = "File mask: ", default = M.active_mask() or "" }, function(input)
      -- nil means the prompt was cancelled, so keep the mask as it was.
      if input ~= nil then
        M.set_mask(input)
      end
      M.live_grep(text)
    end)
  end)
end

local function pick_recent(prompt_bufnr)
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local text = action_state.get_current_line()
  actions.close(prompt_bufnr)

  local recent = read_state().recent
  if #recent == 0 then
    vim.notify("grepmask: no recent masks yet", vim.log.levels.INFO)
    vim.schedule(function()
      M.live_grep(text)
    end)
    return
  end

  require("telescope.pickers")
    .new({}, {
      prompt_title = "Recent File Masks",
      finder = require("telescope.finders").new_table { results = recent },
      sorter = require("telescope.config").values.generic_sorter {},
      attach_mappings = function(recent_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(recent_bufnr)
          if selection then
            M.set_mask(selection[1])
          end
          M.live_grep(text)
        end)
        return true
      end,
    })
    :find()
end

function M.live_grep(default_text)
  local mask = M.active_mask()

  require("telescope.builtin").live_grep {
    default_text = default_text,
    glob_pattern = parse_mask(mask),
    prompt_title = mask and ("Live Grep [" .. mask .. "]") or "Live Grep",
    attach_mappings = function(prompt_bufnr, map)
      for _, mode in ipairs { "i", "n" } do
        map(mode, "<C-f>", function()
          edit_mask(prompt_bufnr)
        end, { desc = "grepmask edit file mask" })
        map(mode, "<C-g>", function()
          pick_recent(prompt_bufnr)
        end, { desc = "grepmask recent file masks" })
      end
      return true
    end,
  }
end

return M
