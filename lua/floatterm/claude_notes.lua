-- Claude's half of a Claude tab's notes: a short sheet kept up to date by a small,
-- cheap Claude (haiku) after each turn.
--
-- When the tab's Claude finishes a turn (the Stop hook, through lua/floatterm/claude)
-- and the tab has notes on, the turn is read from Claude Code's transcript (from the
-- last prompt to the end: the prompt, Claude's replies, and the tools it ran with a
-- short result) and given to `claude -p` with the current sheet, which it rewrites:
-- Links, Branch & commits, Ran, Decisions, Now. The sheet is written beside the
-- user's own notes (floatterm.notes.paths) and FloatTermClaudeNotesChanged is fired
-- with the note_id so the pane can reload it.
--
-- One run at a time per tab. A turn that ends while one is running is remembered, and
-- once that run finishes there's one more with whatever is latest then (not one per
-- turn). If claude is missing or fails, there's one notification per tab and nothing
-- else; the notes just stay as they were.
--
-- The run leaves no trace: --no-session-persistence keeps it out of `claude --resume`,
-- --safe-mode skips hooks (so floatterm's hook can't report it to a tab), CLAUDE.md,
-- plugins and MCP servers, and $FLOATTERM_TAB_ID is emptied anyway, as an nvim
-- inside a floatterm tab would pass its own on.

local M = {}

local MODEL = "haiku"
-- The turn given to Claude is cut to this many characters, keeping the prompt and
-- the end (where the outcome is).
local MAX_TURN = 20000
local MAX_PROMPT = 2000
-- Most turns sit in the last few MB of a transcript; the whole file is only read
-- when the prompt isn't in there.
local TAIL_BYTES = 4 * 1024 * 1024
-- The Stop hook can arrive just before Claude's last reply is in the transcript.
local SETTLE_MS = 1000
local TIMEOUT_MS = 120000

local INSTRUCTIONS = [[
You keep a short notes sheet for a developer about a Claude Code session running in one of their terminal tabs. You are given the current sheet and the latest turn of the session: the user's prompt, Claude's replies, and the tools Claude ran with short results.

Rewrite the sheet so it is useful to glance at later. Output only the sheet as markdown: no preamble, no code fence.

Use these sections, in this order, each a "## " heading with terse bullets. Leave out any section with nothing in it.
## Links - PR, Jira and other URLs worth reopening, a few words on each
## Branch & commits - the branch, and commits made (short hash and subject)
## Ran - commands worth remembering and whether they passed or failed; for a command run several times, only its latest result
## Decisions - what was decided and why, a line each
## Now - where things stand, and what Claude is waiting on, if anything. Rewrite this section from the latest turn every time; never keep an earlier Now line beside a newer one

Keep what is still useful from the current sheet, update what this turn changed, and drop what is stale or routine (file reads, searches, small steps). Never add anything that isn't in the input. Keep it under 40 lines. UK English.]]

-- Per tab id: { running, again, warned }.
local state = {}

local function find(id)
  for _, record in ipairs(require("floatterm").tabs()) do
    if record.id == id then
      return record
    end
  end
  return nil
end

local function wanted(record)
  return record and record.kind == "claude" and record.notes_on and record.note_id and record.transcript_path
end

local function warn_once(record, message)
  local tab = state[record.id]
  if tab and tab.warned then
    return
  end
  if tab then
    tab.warned = true
  end
  vim.notify("Claude's notes: " .. message, vim.log.levels.WARN)
end

-- Same rule as floatterm.notes, for until that module is there.
local start_folder = vim.uv.fs_realpath(vim.uv.cwd())

-- Where the tab's Claude notes are kept, or nil without a note_id.
function M.path(record)
  local ok, paths = pcall(function()
    return require("floatterm.notes").paths(record)
  end)
  if ok then
    return paths and paths.claude
  end
  if not (record.note_id and start_folder) then
    return nil
  end
  return start_folder .. "/.nvim/fterm/notes/" .. record.note_id .. ".claude.md"
end

local function cut(text, limit)
  if #text <= limit then
    return text
  end
  return text:sub(1, limit) .. " …"
end

-- The last `limit` characters, where a command's outcome usually is.
local function tail(text, limit)
  text = vim.trim(text)
  if #text <= limit then
    return text
  end
  return "… " .. text:sub(-limit)
end

local function result_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, "\n")
end

-- The text of a user entry the person typed, or nil for anything else: tool results,
-- skill text and other entries Claude Code adds (isMeta), background tasks and other
-- sessions reporting back, and interruptions.
local function prompt_text(entry)
  if entry.type ~= "user" or entry.isMeta or entry.isSidechain or type(entry.message) ~= "table" then
    return nil
  end
  local origin = type(entry.origin) == "table" and entry.origin.kind or nil
  if origin == "peer" or origin == "task-notification" then
    return nil
  end
  local content = entry.message.content
  local text
  if type(content) == "string" then
    text = content
  elseif type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) ~= "table" or block.type == "tool_result" then
        return nil
      end
      if block.type == "text" and type(block.text) == "string" then
        table.insert(parts, block.text)
      end
    end
    text = table.concat(parts, "\n")
  else
    return nil
  end
  if text:match "^%s*%[Request interrupted" or text:match "^%s*<task%-notification>" then
    return nil
  end
  return text
end

local EDITS = { Edit = "Edited", MultiEdit = "Edited", Write = "Wrote", NotebookEdit = "Edited" }
-- Looking around is routine; only a failure is worth passing on.
local QUIET = { Read = true, Grep = true, Glob = true, LS = true, TodoWrite = true, ToolSearch = true }

-- The turn's lines from the entries after its prompt.
local function describe(entries)
  local lines, tools = {}, {}
  for _, entry in ipairs(entries) do
    local content = type(entry.message) == "table" and entry.message.content or nil
    if entry.isSidechain or type(content) ~= "table" then
      goto continue
    end
    for _, block in ipairs(content) do
      if type(block) ~= "table" then
        goto next_block
      end
      if entry.type == "assistant" and block.type == "text" and vim.trim(block.text or "") ~= "" then
        table.insert(lines, "Claude: " .. vim.trim(block.text))
      elseif entry.type == "assistant" and block.type == "tool_use" then
        local input = type(block.input) == "table" and block.input or {}
        tools[block.id or ""] = block.name
        if block.name == "Bash" then
          table.insert(lines, "$ " .. cut(tostring(input.command or ""), 400))
        elseif EDITS[block.name] then
          table.insert(lines, EDITS[block.name] .. " " .. tostring(input.file_path or input.notebook_path or "?"))
        elseif not QUIET[block.name] then
          local ok, json = pcall(vim.json.encode, input)
          table.insert(lines, "Tool " .. tostring(block.name) .. ": " .. cut(ok and json or "", 200))
        end
      elseif entry.type == "user" and block.type == "tool_result" then
        local name = tools[block.tool_use_id or ""]
        local failed = block.is_error == true
        local text = result_text(block.content)
        if name == "Bash" then
          table.insert(lines, "  -> " .. (failed and "failed: " or "ok: ") .. tail(text, failed and 400 or 200))
        elseif failed then
          table.insert(lines, "  -> " .. tostring(name or "tool") .. " failed: " .. tail(text, 200))
        elseif name and not EDITS[name] and not QUIET[name] then
          table.insert(lines, "  -> " .. cut(vim.trim(text), 200))
        end
      end
      ::next_block::
    end
    ::continue::
  end
  return lines
end

-- The latest turn from transcript `text` (JSONL), as text for Claude, or nil when no
-- prompt is in it. Walks back from the end, only decoding the lines that could be
-- part of a turn.
local function turn_from(text)
  local raw = vim.split(text, "\n", { plain = true, trimempty = true })
  local entries, prompt, branch = {}, nil, nil
  for i = #raw, 1, -1 do
    local line = raw[i]
    if line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(entry) == "table" then
        -- The branch as the turn ended, as Claude may have switched during it.
        branch = branch or (type(entry.gitBranch) == "string" and entry.gitBranch ~= "" and entry.gitBranch or nil)
        prompt = prompt_text(entry)
        if prompt then
          break
        end
        table.insert(entries, 1, entry)
      end
    end
  end
  if not prompt then
    return nil
  end

  local head = (branch and ("Branch: " .. branch .. "\n") or "") .. "User: " .. cut(vim.trim(prompt), MAX_PROMPT)
  local body = table.concat(describe(entries), "\n")
  if #head + #body > MAX_TURN then
    body = "(earlier part of the turn left out)\n…" .. body:sub(-(MAX_TURN - #head))
  end
  return head .. "\n" .. body
end

local function read_file(path, offset, done)
  vim.uv.fs_open(path, "r", 438, function(open_err, fd)
    if open_err then
      return done(nil)
    end
    vim.uv.fs_fstat(fd, function(_, stat)
      local size = stat and stat.size or 0
      local from = math.max(0, size - (offset or size))
      vim.uv.fs_read(fd, size - from, from, function(_, data)
        vim.uv.fs_close(fd)
        if data and from > 0 then
          -- The first line was cut part-way.
          data = data:sub((data:find("\n", 1, true) or #data) + 1)
        end
        done(data, from > 0)
      end)
    end)
  end)
end

-- Calls done(turn or nil) with the latest turn in the transcript at `path`. Reads and
-- parses off the main loop, so a long transcript doesn't hold nvim up.
function M.latest_turn(path, done)
  read_file(path, TAIL_BYTES, function(data, partial)
    local turn = data and turn_from(data)
    if turn or not partial then
      return done(turn)
    end
    read_file(path, nil, function(whole)
      done(whole and turn_from(whole))
    end)
  end)
end

-- Writes `text` to `path` through a temporary file beside it, so the pane never
-- reads half a sheet.
local function write_atomically(path, text)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local temp = dir .. "/." .. vim.fn.fnamemodify(path, ":t") .. "." .. vim.uv.os_getpid() .. ".tmp"
  local file, err = io.open(temp, "w")
  if not file then
    return false, err
  end
  file:write(text)
  file:close()
  local ok, rename_err = vim.uv.fs_rename(temp, path)
  if not ok then
    os.remove(temp)
    return false, rename_err
  end
  return true
end

local function read_notes(path)
  local file = io.open(path, "r")
  if not file then
    return ""
  end
  local text = file:read "*a"
  file:close()
  return text
end

-- The sheet from Claude's answer, without a code fence round it if it added one.
local function sheet_from(answer)
  answer = vim.trim(answer or "")
  answer = answer:gsub("^```%w*\n", ""):gsub("\n```$", "")
  return vim.trim(answer)
end

-- For tests: the last run's { cost_usd, duration_ms }, from claude's JSON output.
M.last = nil

local run

-- After a run: once more if a turn ended meanwhile, otherwise done.
local function finished(id)
  local tab = state[id]
  if not tab then
    return
  end
  if tab.again then
    tab.again = false
    local record = find(id)
    if wanted(record) then
      return run(record)
    end
  end
  tab.running = false
end

function run(record)
  local id = record.id
  local tab = state[id]
  tab.running = true
  local path = M.path(record)
  if not path then
    return finished(id)
  end
  if vim.fn.executable "claude" == 0 then
    warn_once(record, "claude isn't on PATH")
    return finished(id)
  end

  M.latest_turn(record.transcript_path, function(turn)
    vim.schedule(function()
      if not turn then
        return finished(id)
      end
      local current = vim.trim(read_notes(path))
      local input = "Current sheet:\n" .. (current ~= "" and current or "(empty)") .. "\n\nLatest turn:\n" .. turn
      local command = {
        "claude",
        "-p",
        "Update the notes sheet from the turn below.",
        "--model",
        MODEL,
        "--system-prompt",
        INSTRUCTIONS,
        "--tools",
        "",
        "--safe-mode",
        "--no-session-persistence",
        "--output-format",
        "json",
      }
      local opts = {
        cwd = record.cwd or vim.uv.cwd(),
        stdin = input,
        text = true,
        timeout = TIMEOUT_MS,
        env = { FLOATTERM_TAB_ID = "" },
      }
      local ok, err = pcall(vim.system, command, opts, function(result)
        vim.schedule(function()
          local decoded, out = pcall(vim.json.decode, result.stdout or "")
          out = decoded and type(out) == "table" and out or {}
          if result.code ~= 0 or out.is_error or type(out.result) ~= "string" then
            local reason = vim.trim((result.stderr or "") ~= "" and result.stderr or (result.stdout or ""))
            warn_once(record, "claude failed" .. (reason ~= "" and (": " .. cut(reason, 200)) or ""))
            return finished(id)
          end
          M.last = { cost_usd = out.total_cost_usd, duration_ms = out.duration_ms }
          local sheet = sheet_from(out.result)
          if sheet ~= "" then
            local written, write_err = write_atomically(path, sheet .. "\n")
            if written then
              vim.api.nvim_exec_autocmds(
                "User",
                { pattern = "FloatTermClaudeNotesChanged", data = { note_id = record.note_id } }
              )
            else
              warn_once(record, "couldn't write " .. path .. ": " .. tostring(write_err))
            end
          end
          finished(id)
        end)
      end)
      if not ok then
        warn_once(record, "couldn't start claude: " .. tostring(err))
        finished(id)
      end
    end)
  end)
end

local function start(record, delay)
  state[record.id] = state[record.id] or {}
  local tab = state[record.id]
  if tab.running then
    tab.again = true
    return
  end
  tab.running = true
  vim.defer_fn(function()
    local live = find(record.id) or record
    if wanted(live) then
      run(live)
    else
      tab.running = false
    end
  end, delay)
end

-- Called by lua/floatterm/claude when a tab's Claude finishes a turn.
function M.on_stop(record)
  if wanted(record) then
    start(record, SETTLE_MS)
  end
end

-- Rewrites the notes from the latest turn now. `record` defaults to the tab showing.
function M.refresh(record)
  local floatterm = require "floatterm"
  record = record or floatterm.record(floatterm.current_buf() or -1)
  if not (record and record.kind == "claude") then
    vim.notify("Claude's notes: not a Claude tab", vim.log.levels.WARN)
  elseif not (record.notes_on and record.note_id) then
    vim.notify("Claude's notes: this tab's notes are off", vim.log.levels.WARN)
  elseif not record.transcript_path then
    vim.notify("Claude's notes: no conversation yet", vim.log.levels.WARN)
  else
    start(record, 0)
  end
end

-- For tests.
M.turn_from = turn_from
M.state = state

return M
