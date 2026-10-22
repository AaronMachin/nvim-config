-- Debugs PHP with Xdebug running inside Laravel Sail.
--
-- nvim listens on port 9003 and Xdebug in the container connects out to it, so a
-- session starts listening first and stops at a breakpoint once a request comes in.
-- The container's /var/www/html is mapped to the git root of the file the session
-- starts from (or the cwd), so it follows whichever worktree you're in.
--
-- Xdebug only connects when the project's .env has SAIL_XDEBUG_MODE with debug in
-- it and Sail has been restarted. Starting a session warns when it hasn't.

local M = {}

-- Requiring "dap" below makes lazy.nvim load nvim-dap, whose config requires this
-- module again. Registering it first means that inner require gets this table
-- instead of a "loop or previous error" when this module is required before the plugin.
package.loaded.debugger = M

local dap = require "dap"
local dapui = require "dapui"

local PORT = 9003
local CONTAINER_ROOT = "/var/www/html"
local ENV_LINE = "SAIL_XDEBUG_MODE=develop,debug"

local function project_root()
  local file = vim.api.nvim_buf_get_name(0)
  return (file ~= "" and vim.fs.root(file, ".git")) or vim.fn.getcwd()
end

-- The SAIL_XDEBUG_MODE value in root/.env, nil when the file or line is missing.
local function xdebug_mode(root)
  local ok, lines = pcall(vim.fn.readfile, root .. "/.env")
  if not ok then
    return nil
  end
  local mode = nil
  -- Later lines win, as they do for Docker Compose.
  for _, line in ipairs(lines) do
    local value = line:match "^%s*SAIL_XDEBUG_MODE%s*=%s*(.-)%s*$"
    if value then
      mode = value:gsub("^['\"]", ""):gsub("['\"]$", "")
    end
  end
  return mode
end

local function warn_if_xdebug_off(root)
  local mode = xdebug_mode(root)
  if mode and vim.tbl_contains(vim.split(mode, ","), "debug") then
    return
  end
  vim.notify(
    ("debugger: Xdebug isn't in debug mode for %s. Add this to its .env and restart Sail:\n%s"):format(root, ENV_LINE),
    vim.log.levels.WARN
  )
end

dap.adapters.php = {
  type = "executable",
  command = vim.fn.exepath "php-debug-adapter" ~= "" and vim.fn.exepath "php-debug-adapter"
    or vim.fn.stdpath "data" .. "/mason/bin/php-debug-adapter",
}

-- Functions in a configuration are called when the session starts, which is what
-- keeps the mapping on the current worktree rather than wherever nvim was opened.
local LISTEN = {
  type = "php",
  request = "launch",
  name = "Listen for Xdebug (Sail)",
  port = PORT,
  pathMappings = function()
    return { [CONTAINER_ROOT] = project_root() }
  end,
}

dap.configurations.php = { LISTEN }

dap.listeners.on_config.debugger = function(config)
  if config.type == "php" then
    warn_if_xdebug_off(project_root())
  end
  return config
end

dapui.setup()

dap.listeners.after.event_initialized.debugger = function()
  dapui.open()
end
dap.listeners.before.event_terminated.debugger = function()
  dapui.close()
end
dap.listeners.before.event_exited.debugger = function()
  dapui.close()
end
dap.listeners.before.disconnect.debugger = function()
  dapui.close()
end

-- The highlights come from base46's dap integration, which NvChad only compiles when
-- chadrc lists it, so it's applied here and again whenever the theme changes.
local function apply_highlights()
  local ok, highlights = pcall(function()
    return require("base46").get_integration "dap"
  end)
  if not ok then
    return
  end
  for name, value in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, value)
  end
end

apply_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("debugger", { clear = true }),
  callback = apply_highlights,
})

local signs = {
  DapBreakpoint = { text = "●", texthl = "DapBreakpoint" },
  DapBreakpointCondition = { text = "◆", texthl = "DapBreakpointCondition" },
  DapLogPoint = { text = "◆", texthl = "DapLogPoint" },
  DapBreakpointRejected = { text = "○", texthl = "Comment" },
  DapStopped = { text = "→", texthl = "DapStopped", linehl = "Visual" },
}
for name, sign in pairs(signs) do
  vim.fn.sign_define(name, sign)
end

-- Starts listening when there's no session, from any buffer (not just PHP ones),
-- and otherwise carries on to the next breakpoint.
function M.continue()
  if dap.session() then
    dap.continue()
  else
    dap.run(LISTEN)
  end
end

function M.toggle_breakpoint()
  dap.toggle_breakpoint()
end

function M.conditional_breakpoint()
  vim.ui.input({ prompt = "Breakpoint condition: " }, function(condition)
    if condition and condition ~= "" then
      dap.set_breakpoint(condition)
    end
  end)
end

function M.step_over()
  dap.step_over()
end

function M.step_into()
  dap.step_into()
end

function M.step_out()
  dap.step_out()
end

function M.stop()
  dap.terminate()
end

function M.toggle_ui()
  dapui.toggle()
end

-- The word under the cursor, or the selection in visual mode.
function M.eval()
  dapui.eval()
end

-- For the tests and anyone curious which root a session would map to.
M.project_root = project_root

return M
