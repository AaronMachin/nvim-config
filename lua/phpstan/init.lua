-- Runs PHPStan for the project through Sail and puts the errors in the quickfix list.
--
-- It has to run in the Sail container, as Larastan boots the app and host PHP can't
-- reach the database host named in .env. The container sees the project at
-- /var/www/html, so its paths are mapped back to the project before going in the list.

local M = {}

local CONTAINER_ROOT = "/var/www/html"
local COMMAND = {
  "./vendor/bin/sail",
  "php",
  "vendor/bin/phpstan",
  "analyse",
  "--error-format=raw",
  "--no-progress",
  "--memory-limit=1G",
}

local running = false

local function project_root()
  local file = vim.api.nvim_buf_get_name(0)
  return vim.fs.root(file ~= "" and file or vim.uv.cwd(), { "phpstan.neon", "phpstan.neon.dist" })
end

-- Raw format is one error a line: "<file>:<line>:<message>". The line is "?" for an
-- error PHPStan can't place in the file, and the file is "?" too when it isn't about a
-- file at all (bad config, say). Errors in a trait name the class they were checked
-- for after the path, "<file> (in context of class App\Models\Site)", which goes
-- on the end of the message so the path is one the quickfix list can open.
function M.parse(output, root)
  local items = {}
  for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
    -- The first ":<line>:" ends the path, as the message can have colons of its own.
    local file, lnum, text = line:match "^(.-):([%d?]+):(.*)$"
    if file and file ~= "?" then
      text = vim.trim(text)
      local path, context = file:match "^(.-)%s+%((in context of .-)%)$"
      if path then
        file = path
        text = text .. " (" .. context .. ")"
      end
      if file:sub(1, #CONTAINER_ROOT + 1) == CONTAINER_ROOT .. "/" then
        file = root .. file:sub(#CONTAINER_ROOT + 1)
      end
      -- No line means the top of the file, so the entry still opens it.
      table.insert(items, { filename = file, lnum = tonumber(lnum) or 1, text = text })
    elseif file then
      table.insert(items, { text = vim.trim(text) })
    end
  end
  return items
end

local function finish(result, root)
  running = false
  local output = (result.stdout or "") .. "\n" .. (result.stderr or "")

  if output:find "Sail is not running" or output:find "Docker or Podman is not running" then
    vim.notify("PHPStan: Sail isn't running (./vendor/bin/sail up -d)", vim.log.levels.WARN)
    return
  end

  -- Sail passes AI agents' environment variables into the container, and PHPStan
  -- then prints a JSON summary in place of the raw format. That happens when nvim
  -- was started from an agent's shell, and the summary has no lines to list.
  local ok, summary = pcall(vim.json.decode, vim.trim(result.stdout or ""))
  if ok and type(summary) == "table" and summary.tool == "phpstan" then
    if summary.errors == 0 then
      vim.notify "PHPStan: no errors"
    else
      local count = tostring(summary.errors)
      vim.notify(
        "PHPStan: " .. count .. " errors, but only a summary came back (nvim was started from an AI agent's shell)",
        vim.log.levels.WARN
      )
    end
    return
  end

  local items = M.parse(result.stdout or "", root)
  -- 0 is clean and 1 is errors found. Anything else, or 1 with nothing parsed, means
  -- PHPStan itself fell over.
  if result.code > 1 or (result.code == 1 and #items == 0) then
    local reason = vim.trim(result.stderr ~= "" and result.stderr or result.stdout or "")
    vim.notify("PHPStan failed (exit " .. result.code .. "): " .. reason:sub(1, 500), vim.log.levels.ERROR)
    return
  end

  vim.fn.setqflist({}, " ", { title = "PHPStan", items = items })
  if #items == 0 then
    vim.notify "PHPStan: no errors"
    return
  end
  vim.cmd "copen"
  vim.notify("PHPStan: " .. #items .. (#items == 1 and " error" or " errors"), vim.log.levels.WARN)
end

function M.run()
  local root = project_root()
  if not root then
    vim.notify("PHPStan: no phpstan.neon in this project", vim.log.levels.WARN)
    return
  end
  if not vim.uv.fs_stat(root .. "/vendor/bin/sail") then
    vim.notify("PHPStan: this project has no vendor/bin/sail", vim.log.levels.WARN)
    return
  end
  if running then
    vim.notify("PHPStan: already running", vim.log.levels.WARN)
    return
  end

  running = true
  vim.notify "PHPStan: running in Sail, this takes a while"
  vim.system(COMMAND, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      finish(result, root)
    end)
  end)
end

return M
