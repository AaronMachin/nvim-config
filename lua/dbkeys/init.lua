-- Opens dadbod-ui on the project's own database, read from its .env.
--
-- .env holds what the app sees inside Sail (DB_HOST=pgsql, say), so the connection
-- goes to 127.0.0.1 on the port Sail forwards to the host instead. It's registered
-- in vim.g.dbs under the project folder's name. The password goes into the URL and
-- nowhere else: nothing here prints the URL.

local M = {}

local LIBPQ_BIN = "/opt/homebrew/opt/libpq/bin"

local function project_root()
  local file = vim.api.nvim_buf_get_name(0)
  local start = (file ~= "" and vim.bo.buftype == "") and file or vim.uv.cwd()
  return vim.fs.root(start, ".git")
end

-- KEY=value lines, with quotes taken off and comments skipped. Variables inside
-- values (${APP_NAME}) aren't expanded, as none of the DB_* ones use them.
function M.read_env(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end

  local env = {}
  for _, line in ipairs(lines) do
    local key, value = line:match "^%s*export%s+([%w_]+)%s*=%s*(.-)%s*$"
    if not key then
      key, value = line:match "^%s*([%w_]+)%s*=%s*(.-)%s*$"
    end
    if key then
      local quoted = value:match '^"(.*)"$' or value:match "^'(.*)'$"
      if quoted then
        value = quoted
      else
        value = value:gsub("%s+#.*$", "")
      end
      env[key] = value
    end
  end
  return env
end

local function encode(text)
  return (text:gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function credentials(env)
  local user = env.DB_USERNAME or ""
  if user == "" then
    return ""
  end
  local password = env.DB_PASSWORD or ""
  return encode(user) .. (password ~= "" and (":" .. encode(password)) or "") .. "@"
end

-- The dadbod URL for a project's .env, or nil and the reason it can't be built.
function M.build_url(env, root)
  local connection = env.DB_CONNECTION or ""
  local database = env.DB_DATABASE or ""

  if connection == "pgsql" then
    local port = env.FORWARD_DB_PORT ~= nil and env.FORWARD_DB_PORT ~= "" and env.FORWARD_DB_PORT or "5432"
    return "postgresql://" .. credentials(env) .. "127.0.0.1:" .. port .. "/" .. encode(database)
  end

  if connection == "mysql" or connection == "mariadb" then
    local port = env.FORWARD_DB_PORT ~= nil and env.FORWARD_DB_PORT ~= "" and env.FORWARD_DB_PORT or "3306"
    return "mysql://" .. credentials(env) .. "127.0.0.1:" .. port .. "/" .. encode(database)
  end

  if connection == "sqlite" then
    -- Laravel's default when DB_DATABASE is unset. A relative path is from the project.
    local path = database ~= "" and database or "database/database.sqlite"
    if path ~= ":memory:" and path:sub(1, 1) ~= "/" then
      path = root .. "/" .. path
    end
    if path ~= ":memory:" and not vim.uv.fs_stat(path) then
      return nil, "the SQLite file " .. path .. " doesn't exist"
    end
    return "sqlite:" .. path
  end

  if connection == "" then
    return nil, ".env has no DB_CONNECTION"
  end
  return nil, "DB_CONNECTION=" .. connection .. " isn't supported (pgsql, mysql, mariadb or sqlite)"
end

-- Registers the connection under `name`, replacing an older one of the same name,
-- and returns whether anything changed.
local function register(name, url)
  local dbs = vim.g.dbs or {}
  if vim.islist(dbs) and #dbs > 0 then
    for _, db in ipairs(dbs) do
      if db.name == name then
        if db.url == url then
          return false
        end
        db.url = url
        vim.g.dbs = dbs
        return true
      end
    end
    table.insert(dbs, { name = name, url = url })
  else
    if dbs[name] == url then
      return false
    end
    dbs[name] = url
  end
  -- vim.g hands back a copy, so the whole table goes back in.
  vim.g.dbs = dbs
  return true
end

function M.open()
  local root = project_root()
  if not root then
    vim.notify("dbkeys: not in a git repository", vim.log.levels.WARN)
    return
  end

  local env = M.read_env(root .. "/.env")
  if not env then
    vim.notify("dbkeys: no .env in " .. root, vim.log.levels.WARN)
    return
  end

  local url, reason = M.build_url(env, root)
  if not url then
    vim.notify("dbkeys: " .. reason, vim.log.levels.WARN)
    return
  end

  if env.DB_CONNECTION == "pgsql" and vim.fn.executable "psql" == 0 then
    vim.env.PATH = LIBPQ_BIN .. ":" .. vim.env.PATH
    if vim.fn.executable "psql" == 0 then
      vim.notify("dbkeys: psql isn't installed (brew install libpq)", vim.log.levels.WARN)
      return
    end
  end

  local name = vim.fn.fnamemodify(root, ":t")
  -- dadbod-ui reads vim.g.dbs once, the first time it opens, so a changed connection
  -- needs its state cleared to show up.
  if register(name, url) and vim.fn.exists "*db_ui#reset_state" == 1 then
    vim.fn["db_ui#reset_state"]()
  end

  vim.cmd "DBUI"
end

return M
