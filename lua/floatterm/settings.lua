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
  -- Where Claude's summary of a Claude tab's session (lua/floatterm/claude_notes)
  -- shows: "bar" (under the tab bar), "pane" (in the notes pane beside the terminal,
  -- which then opens for Claude tabs by itself), "asked" (only in the large float,
  -- Ctrl+Shift+o) or "off" (not written at all). And the model that writes it: "haiku"
  -- or "sonnet".
  claude_summary = "bar",
  claude_notes_model = "haiku",
  -- The most of the tab bar's height (or the notes pane's) the summary takes, less
  -- when it's short.
  claude_notes_share = 0.65,
  -- What leads each tab in the tab bar (lua/floatterm/emoji): "emoji", or "symbols"
  -- (a coloured shape) for a terminal whose font draws emoji badly.
  tab_icons = "emoji",
  -- The labels the tab bar's t puts on a tab (lua/floatterm/marks): the second key,
  -- the word and its colour (green, blue, red, grey, purple, yellow, cyan, orange).
  -- Only done greys the tab out.
  marks = {
    { key = "d", word = "done", colour = "green" },
    { key = "r", word = "review", colour = "blue" },
    { key = "b", word = "blocked", colour = "red" },
    { key = "p", word = "parked", colour = "grey" },
  },
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
        -- A list (the marks) is taken whole; a table of named parts fills in defaults.
        if type(default) == "table" and not vim.islist(default) then
          values[key] = vim.tbl_extend("force", default, saved[key])
        else
          values[key] = saved[key]
        end
      end
    end
    -- Claude's notes switched off, from before claude_summary had an "off".
    if saved.claude_notes == false and saved.claude_summary == nil then
      values.claude_summary = "off"
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
