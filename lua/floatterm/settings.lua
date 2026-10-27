-- Floating terminal settings. Defaults live here; this machine's choices are kept in
-- stdpath("data")/floatterm-settings.json, which the configuration page writes.
-- Changing one fires the User event FloatTermSettingsChanged with data = { key = ... }.

local M = {}

-- A field rather than a local so tests can point it somewhere other than the live file.
M.path = vim.fn.stdpath "data" .. "/floatterm-settings.json"

M.defaults = {
  -- Where the tab bar sits inside the float: "left", "top" or "off".
  tabbar = "left",
  tabbar_width = 28,
  -- Where the terminal opens in a project that hasn't used it yet (after that it opens
  -- where it was last): "bottom", "top", "left", "right", "box" or "split".
  start_position = "bottom",
  -- Docked, the float takes this share of the editor's height (top/bottom) or width
  -- (left/right).
  dock_sizes = { large = 0.9, small = 0.2 },
  hints = true,
  reopen_tabs = true,
  -- The Claude sessions bookmark in the top right of the editor.
  bookmark = true,
  -- Where a tab's notes pane sits beside its terminal ("left", "right", "top",
  -- "bottom"), and the share of the terminal's room it takes.
  notes_side = "right",
  notes_share = 0.35,
  -- Whether Claude's half of a Claude tab's notes is kept up to date after each turn
  -- (lua/floatterm/claude_notes), and the model that does it: "haiku" or "sonnet".
  claude_notes = true,
  claude_notes_model = "haiku",
}

local values = nil

local function load()
  values = vim.deepcopy(M.defaults)
  local file = io.open(M.path, "r")
  if not file then
    return
  end

  local ok, saved = pcall(vim.json.decode, file:read "*a")
  file:close()
  if ok and type(saved) == "table" then
    -- Only known keys, so a setting dropped from the defaults doesn't linger.
    for key, default in pairs(M.defaults) do
      if saved[key] ~= nil and type(saved[key]) == type(default) then
        values[key] = type(default) == "table" and vim.tbl_extend("force", default, saved[key]) or saved[key]
      end
    end
  end
end

local function save()
  local file = io.open(M.path, "w")
  if not file then
    vim.notify("floatterm: could not write " .. M.path, vim.log.levels.WARN)
    return
  end
  file:write(vim.json.encode(values))
  file:close()
end

function M.get(key)
  if not values then
    load()
  end
  return values[key]
end

-- A copy of every setting.
function M.all()
  if not values then
    load()
  end
  return vim.deepcopy(values)
end

function M.set(key, value)
  if M.defaults[key] == nil then
    error("floatterm: no setting called " .. key)
  end
  if not values then
    load()
  end
  values[key] = value
  save()
  vim.api.nvim_exec_autocmds("User", { pattern = "FloatTermSettingsChanged", data = { key = key } })
end

-- Forgets the loaded values so the next get reads the file again. For tests.
function M.reload()
  values = nil
end

return M
