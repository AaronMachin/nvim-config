-- Helpers for the <leader>g git keys that need more than one call.

local M = {}

-- The remote's default branch (origin/HEAD), falling back to main.
local function default_branch(root)
  local result = vim.system({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { cwd = root }):wait()
  if result.code == 0 then
    return vim.trim(result.stdout)
  end
  return "main"
end

-- Opens diffview with everything this branch changes since it left the default
-- branch, or closes it if it's open.
function M.toggle_branch_review()
  if require("diffview.lib").get_current_view() then
    vim.cmd "DiffviewClose"
    return
  end

  local root = vim.fs.root(0, ".git") or vim.uv.cwd()
  vim.cmd("DiffviewOpen " .. default_branch(root) .. "...HEAD")
end

-- Opens the current file at the cursor's line (or the selected lines) on GitHub,
-- on the current branch, or at the commit when HEAD is detached. The branch or commit
-- has to be pushed for the page to exist.
function M.open_on_github()
  local file = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(file, ".git")
  if not root then
    vim.notify("gitkeys: not in a git repository", vim.log.levels.WARN)
    return
  end

  local first, last = vim.fn.line ".", vim.fn.line "v"
  if first > last then
    first, last = last, first
  end
  local lines = first == last and tostring(first) or (first .. "-" .. last)

  local branch = vim.trim(vim.system({ "git", "branch", "--show-current" }, { cwd = root }):wait().stdout)
  local args = { "gh", "browse", file:sub(#root + 2) .. ":" .. lines }
  if branch ~= "" then
    vim.list_extend(args, { "--branch", branch })
  else
    -- gh's --commit takes its value only after "=", as on its own it means the last commit.
    local commit = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { cwd = root }):wait().stdout or "")
    if commit ~= "" then
      table.insert(args, "--commit=" .. commit)
    end
  end

  vim.system(args, { cwd = root }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("gitkeys: " .. vim.trim(result.stderr), vim.log.levels.WARN)
      end)
    end
  end)
end

-- Opens the Jira ticket named at the start of the branch, so SD-486-backend opens
-- SD-486.
function M.open_ticket()
  local root = vim.fs.root(0, ".git") or vim.uv.cwd()
  local branch = vim.trim(vim.system({ "git", "branch", "--show-current" }, { cwd = root }):wait().stdout or "")
  local key = branch:match "^%u+%-%d+"
  if not key then
    local name = branch ~= "" and branch or "a detached HEAD"
    vim.notify("gitkeys: " .. name .. " doesn't start with a Jira key", vim.log.levels.WARN)
    return
  end

  vim.ui.open("https://totara.atlassian.net/browse/" .. key)
end

return M
