-- Settings for this machine (JIRA_URL, say), from .env next to init.lua: a copy of
-- .env.example, kept out of git. A variable already set in the shell wins.

local M = {}

M.path = vim.fn.stdpath "config" .. "/.env"

function M.load(path)
  local env = require("dbkeys").read_env(path or M.path) or {}
  for key, value in pairs(env) do
    if (vim.env[key] == nil or vim.env[key] == "") and value ~= "" then
      vim.env[key] = value
    end
  end
end

return M
