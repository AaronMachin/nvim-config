-- Runs Pest tests in a floating-terminal tab, through Sail when the project has it.
--
-- The nearest test is the closest it(...) or test(...) at or above the cursor, run
-- with --filter on its description. The last command is kept so it can be run again,
-- along with the tab it ran in so its output can be read back (see lua/agent).

local M = {}

local last = nil

local function project_root(file)
  return vim.fs.root(file, { "artisan", "composer.json" })
end

-- ./vendor/bin/sail artisan test when Sail is installed, else php artisan test.
local function test_command(root)
  if vim.uv.fs_stat(root .. "/vendor/bin/sail") then
    return "./vendor/bin/sail artisan test --compact"
  end
  return "php artisan test --compact"
end

-- The description of the closest it("...") or test("...") at or above the cursor.
local function nearest_test_name()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, cursor, false)
  for i = #lines, 1, -1 do
    local kind, name = lines[i]:match "^%s*(%a+)%s*%(%s*['\"](.-)['\"]"
    if (kind == "it" or kind == "test") and name then
      return name
    end
  end
  return nil
end

local function run(command, root)
  last = { command = command, root = root }
  local _, buf = require("floatterm").run_in_tab("cd " .. vim.fn.shellescape(root) .. " && " .. command)
  last.buf = buf
end

-- `scope` is "nearest" (the test at the cursor) or "file".
function M.run(scope)
  local file = vim.api.nvim_buf_get_name(0)
  local root = project_root(file)
  if not root or not file:match "Test%.php$" then
    vim.notify("testrun: not a Pest test file", vim.log.levels.WARN)
    return
  end

  local command = test_command(root) .. " " .. vim.fn.shellescape(file:sub(#root + 2))
  if scope == "nearest" then
    local name = nearest_test_name()
    if not name then
      vim.notify("testrun: no it() or test() above the cursor", vim.log.levels.WARN)
      return
    end
    -- --filter is a regex, so the description's own punctuation is escaped.
    local pattern = vim.fn.escape(name, [[\^$.*+?()[]{}|/]])
    command = command .. " --filter=" .. vim.fn.shellescape(pattern)
  end

  run(command, root)
end

function M.run_last()
  if not last then
    vim.notify("testrun: no test run yet", vim.log.levels.WARN)
    return
  end
  run(last.command, last.root)
end

-- The last run's command, or nil before the first run.
function M.last_command()
  return last and last.command
end

-- The lines in the last run's terminal tab, trailing blank lines dropped, or nil if
-- there's been no run or its tab has since been closed.
function M.last_output()
  if not (last and last.buf and vim.api.nvim_buf_is_valid(last.buf)) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(last.buf, 0, -1, false)
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return lines
end

return M
