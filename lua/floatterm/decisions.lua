-- How many decisions are waiting for you on each Claude tab, from the decisions mod
-- (if it's installed). The mod keeps each decision as a file,
-- ~/.claude/decisions/<repo>/d<n>.json, with the Claude session it belongs to
-- (`session`) and its state. One is waiting for you while its state is "open" or
-- "live" and it's in the "needs you" section, as the mod itself counts them. A tab's
-- session id comes from Claude's hooks (lua/floatterm/claude).
--
-- The files are looked at again at most every CHECK_MS, and only the ones whose size
-- or time changed are read, so the tab bar's once-a-second redraw stays cheap.
-- Without ~/.claude/decisions every count is 0.

local M = {}

-- A field so tests can point it somewhere else.
M.root = vim.g.floatterm_decisions_dir or vim.fn.expand "~/.claude/decisions"
M.CHECK_MS = 2000

-- By file path: { key (its size and time), session, waiting }.
local files = {}
-- By session id: how many are waiting.
local counts = {}
local checked_at = nil

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read "*a"
  file:close()
  local ok, decision = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(decision) == "table" and decision or nil
end

local function waiting(decision)
  local state = decision.state
  return (state == "open" or state == "live") and (decision.section == nil or decision.section == "needs-you")
end

-- Looks at the files again, reading the ones that changed.
function M.refresh()
  checked_at = vim.uv.now()
  local seen = {}
  local stores = vim.uv.fs_scandir(M.root)
  while stores do
    local store, kind = vim.uv.fs_scandir_next(stores)
    if not store then
      break
    end
    if kind == "directory" then
      local dir = M.root .. "/" .. store
      local entries = vim.uv.fs_scandir(dir)
      while entries do
        local name = vim.uv.fs_scandir_next(entries)
        if not name then
          break
        end
        if name:match "^d%d+%.json$" then
          local path = dir .. "/" .. name
          local stat = vim.uv.fs_stat(path)
          if stat then
            seen[path] = true
            local key = stat.size .. ":" .. stat.mtime.sec .. "." .. stat.mtime.nsec
            if not (files[path] and files[path].key == key) then
              local decision = read(path)
              files[path] = {
                key = key,
                session = decision and decision.session,
                waiting = decision ~= nil and waiting(decision),
              }
            end
          end
        end
      end
    end
  end
  for path in pairs(files) do
    if not seen[path] then
      files[path] = nil
    end
  end
  counts = {}
  for _, file in pairs(files) do
    if file.waiting and type(file.session) == "string" then
      counts[file.session] = (counts[file.session] or 0) + 1
    end
  end
end

-- How many decisions are waiting for you on the Claude tab `record`.
function M.count(record)
  if not (record and record.kind == "claude" and type(record.session_id) == "string") then
    return 0
  end
  if not checked_at or vim.uv.now() - checked_at >= M.CHECK_MS then
    M.refresh()
  end
  return counts[record.session_id] or 0
end

-- Forgets what was read. For tests.
function M.reset()
  files, counts, checked_at = {}, {}, nil
end

return M
