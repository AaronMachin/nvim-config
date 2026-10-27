-- Claude's half of a Claude tab's notes: a short sheet kept up to date by a small,
-- cheap Claude (the claude_notes_model setting, haiku by default) after each turn.
-- The claude_notes setting switches it off everywhere.
--
-- When the tab's Claude finishes a turn (the Stop hook, through lua/floatterm/claude)
-- and the tab has notes on, the turn is read from Claude Code's transcript (from the
-- last prompt to the end: the prompt, Claude's replies, and the tools it ran with a
-- short result) and given to `claude -p` with the current sheet, which it rewrites:
-- Now, Links, Branch & commits, Ran, Decisions (most urgent first, as the pane may only
-- have room for the top). Anything that looks like a secret
-- (tokens, keys, passwords) is replaced with [redacted] before it's sent. The sheet is
-- written beside the user's own notes (floatterm.notes.paths) and
-- FloatTermClaudeNotesChanged is fired with the note_id so the pane can reload it.
--
-- Two tabs can share a note. Only the first of them (in tab order) with notes on keeps
-- Claude's half up to date, so they don't overwrite each other.
--
-- One run at a time per tab. A turn that ends while one is running is remembered, and
-- once that run finishes there's one more with whatever is latest then (not one per
-- turn). If claude is missing or fails, there's one notification per tab and nothing
-- else; the notes just stay as they were. A run whose tab closed, switched notes off
-- or moved to another note while it ran writes nothing.
--
-- The run leaves no trace: --no-session-persistence keeps it out of `claude --resume`,
-- --safe-mode skips hooks (so floatterm's hook can't report it to a tab), CLAUDE.md,
-- plugins and MCP servers, and $FLOATTERM_TAB_ID is emptied anyway, as an nvim
-- inside a floatterm tab would pass its own on.

local M = {}

local settings = require "floatterm.settings"

local MODELS = { haiku = true, sonnet = true }
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

Use these sections, in this order, each a "## " heading with terse bullets. Leave out any section with nothing in it. The sheet is often cut off at the bottom, so the most urgent comes first.
## Now - where things stand, and what Claude is waiting on, if anything. Rewrite this section from the latest turn every time; never keep an earlier Now line beside a newer one
## Links - PR, Jira and other URLs worth reopening, a few words on each
## Branch & commits - the branch, and commits made (short hash and subject)
## Ran - commands worth remembering and whether they passed or failed; for a command run several times, only its latest result
## Decisions - what was decided and why, a line each

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
    and settings.get "claude_notes"
end

-- Whether `record` is the tab that keeps its note's Claude half: the first in tab order
-- that wants it.
local function keeps(record)
  if not wanted(record) then
    return false
  end
  for _, other in ipairs(require("floatterm").tabs()) do
    if wanted(other) and other.note_id == record.note_id then
      return other == record
    end
  end
  return false
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

-- Where the tab's Claude notes are kept, or nil without a note_id. Only a missing notes
-- module falls back: an error from it (no folder for the notes) is the run's to handle.
function M.path(record)
  local ok, notes = pcall(require, "floatterm.notes")
  if ok then
    local paths = notes.paths(record)
    return paths and paths.claude
  end
  if not (record.note_id and start_folder) then
    return nil
  end
  return start_folder .. "/.nvim/fterm/notes/" .. record.note_id .. ".claude.md"
end

local REDACTED = "[redacted]"

-- Key names whose values are secrets: password, passwd or secret anywhere in the name,
-- or ending in token or api key (so max_tokens is kept).
local function secret_name(name)
  name = name:lower()
  return name:find "password" or name:find "passwd" or name:find "secret" or name:find "token$"
    or name:find "api[_%-]?key$"
end

local function entropy(text)
  local counts = {}
  for c in text:gmatch "." do
    counts[c] = (counts[c] or 0) + 1
  end
  local bits = 0
  for _, n in pairs(counts) do
    local p = n / #text
    bits = bits - p * math.log(p) / math.log(2)
  end
  return bits
end

local function mixed(text)
  return text:find "%u" and text:find "%l" and text:find "%d"
end

-- A long run of key characters is taken for a key when it mixes upper case, lower case
-- and digits in one long piece. Hex hashes (no upper case) and paths or branch names
-- made of short words between / - _ are kept.
local function looks_random(run)
  if #run < 40 or not mixed(run) then
    return false
  end
  -- An AWS secret access key: 40 characters of base64, no padding.
  if #run == 40 and not run:find "[_%-=]" and run:sub(1, 1) ~= "/" then
    return true
  end
  for piece in run:gmatch "[^/_%-]+" do
    if #piece >= 20 and mixed(piece) and entropy(piece) >= 3.5 then
      return true
    end
  end
  return false
end

-- `name=value`, `name: value`, `"name":"value"` (escaped quotes too, as in a tool's
-- JSON input) and `--name value`, for a secret name. Only the name and separator are
-- stepped over, so a name inside an unrelated value (a URL's ?token=) is still seen.
local function redact_values(text)
  local out, from = {}, 1
  while true do
    local s, e, name, quote = text:find("([%w_%-]+)[\\\"']*%s*[:=]%s*([\\\"']*)", from)
    if not s then
      break
    end
    table.insert(out, text:sub(from, e))
    from = e + 1
    -- A quoted value can hold spaces, so it runs to the closing quote.
    local _, value_end = text:find(quote ~= "" and "^[^\\\"'\n]+" or "^[^%s\\\"'&;,]+", from)
    if value_end and secret_name(name) then
      table.insert(out, REDACTED)
      from = value_end + 1
    end
  end
  table.insert(out, text:sub(from))
  text = table.concat(out)
  return (text:gsub("(%-%-([%w_%-]+)%s+)([^%s%-][^%s]*)", function(flag, name)
    if secret_name(name) then
      return flag .. REDACTED
    end
  end))
end

-- Replaces anything that looks like a secret with [redacted]: private keys, auth
-- headers and bearer tokens, password/secret/token/api key values, AWS, GitHub and
-- Slack keys, JWTs and long random strings. Only ever sees text on its way to Claude.
local function redact(text)
  local pem = "%-%-%-%-%-BEGIN[%u ]*PRIVATE KEY%-%-%-%-%-"
  text = text:gsub(pem .. ".-%-%-%-%-%-END[%u ]*PRIVATE KEY%-%-%-%-%-", REDACTED)
  -- One cut off before its end.
  text = text:gsub(pem .. "[%w%+/=%s\\]*", REDACTED)
  text = text:gsub("([Aa]uthorization[\\\"']*%s*[:=]%s*[\\\"']*)[^\n\"'\\]+", "%1" .. REDACTED)
  text = text:gsub("([Bb]earer%s+)([%w%-%._~%+/]+=*)", function(before, token)
    if #token >= 8 then
      return before .. REDACTED
    end
  end)
  text = redact_values(text)
  text = text:gsub("%f[%w]A[KS]IA" .. string.rep("[%u%d]", 16) .. "%f[^%w]", REDACTED)
  text = text:gsub("%f[%w]gh[pousr]_%w+", REDACTED)
  text = text:gsub("%f[%w]github_pat_[%w_]+", REDACTED)
  text = text:gsub("%f[%w]xox[abposr]%-[%w%-]+", REDACTED)
  text = text:gsub("%f[%w_%-]eyJ[%w_%-]+%.[%w_%-]+%.[%w_%-]*", REDACTED)
  text = text:gsub("[%w%+/=_%-]+", function(run)
    if looks_random(run) then
      return REDACTED
    end
  end)
  return text
end

-- Redacted before cutting, so a secret cut part-way can't slip through as a piece.
local function cut(text, limit)
  text = redact(text)
  if #text <= limit then
    return text
  end
  return text:sub(1, limit) .. " …"
end

-- The last `limit` characters, where a command's outcome usually is.
local function tail(text, limit)
  text = vim.trim(redact(text))
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
      -- Anything in a block can be some other type in a transcript we don't expect.
      local text = type(block.text) == "string" and block.text or ""
      if entry.type == "assistant" and block.type == "text" and vim.trim(text) ~= "" then
        table.insert(lines, "Claude: " .. vim.trim(redact(text)))
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

-- A transcript line we don't expect gives no turn rather than an error.
local function safe_turn_from(text)
  local ok, turn = pcall(turn_from, text)
  return ok and turn or nil
end

-- Calls done(turn or nil) with the latest turn in the transcript at `path`. The read
-- doesn't block, but the parsing runs in libuv's callback, which is on the main loop:
-- reading only the tail keeps that short.
function M.latest_turn(path, done)
  read_file(path, TAIL_BYTES, function(data, partial)
    local turn = data and safe_turn_from(data)
    if turn or not partial then
      return done(turn)
    end
    read_file(path, nil, function(whole)
      done(whole and safe_turn_from(whole))
    end)
  end)
end

-- Writes `text` to `path` through a temporary file beside it, so the pane never
-- reads half a sheet. A failed write leaves the old sheet and no temporary file.
local function write_atomically(path, text)
  local dir = vim.fn.fnamemodify(path, ":h")
  local made, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
  if not made then
    return false, mkdir_err
  end
  local temp = dir .. "/." .. vim.fn.fnamemodify(path, ":t") .. "." .. vim.uv.os_getpid() .. ".tmp"
  local file, err = io.open(temp, "w")
  if not file then
    return false, err
  end
  local wrote, write_err = file:write(text)
  local closed, close_err = file:close()
  if not (wrote and closed) then
    os.remove(temp)
    return false, write_err or close_err
  end
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
  -- Nil for something that isn't a readable file (a folder, say).
  local text = file:read "*a"
  file:close()
  return text or ""
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
    if keeps(record) then
      return run(record)
    end
  end
  tab.running = false
end

-- `fn` with any error ending the run, or the tab would stay running and its notes
-- would never update again. The guarded part must end with finished, or with handing
-- over to the next guarded part.
local function guarded(id, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      warn_once({ id = id }, "update failed: " .. tostring(err):sub(1, 200))
      finished(id)
    end
  end
end

-- Whether a run started for note `note_id` may still write it: its tab is still open,
-- still wants notes, still has that note and is still the one keeping it.
local function may_write(id, note_id)
  local record = find(id)
  return keeps(record) and record.note_id == note_id
end

function run(record)
  local id, note_id = record.id, record.note_id
  state[id].running = true

  -- The answer: written only if the run may still write this note.
  local function write(result)
    local decoded, out = pcall(vim.json.decode, result.stdout or "")
    out = decoded and type(out) == "table" and out or {}
    if result.code ~= 0 or out.is_error or type(out.result) ~= "string" then
      local reason = vim.trim((result.stderr or "") ~= "" and result.stderr or (result.stdout or ""))
      warn_once(record, "claude failed" .. (reason ~= "" and (": " .. cut(reason, 200)) or ""))
      return finished(id)
    end
    M.last = { cost_usd = out.total_cost_usd, duration_ms = out.duration_ms }
    local sheet = sheet_from(out.result)
    -- The path again, from the note the run started with, not whatever the tab has now.
    local path = M.path { note_id = note_id }
    if sheet ~= "" and path and may_write(id, note_id) then
      local written, write_err = write_atomically(path, sheet .. "\n")
      if written then
        vim.api.nvim_exec_autocmds("User", { pattern = "FloatTermClaudeNotesChanged", data = { note_id = note_id } })
      else
        warn_once(record, "couldn't write " .. path .. ": " .. tostring(write_err))
      end
    end
    finished(id)
  end

  -- With the turn read: asks Claude for the new sheet.
  local function ask(path, turn)
    if not turn then
      return finished(id)
    end
    local current = vim.trim(read_notes(path))
    local input = redact("Current sheet:\n" .. (current ~= "" and current or "(empty)") .. "\n\nLatest turn:\n" .. turn)
    local model = settings.get "claude_notes_model"
    local command = {
      "claude",
      "-p",
      "Update the notes sheet from the turn below.",
      "--model",
      MODELS[model] and model or "haiku",
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
      vim.schedule(guarded(id, function()
        write(result)
      end))
    end)
    if not ok then
      warn_once(record, "couldn't start claude: " .. tostring(err))
      finished(id)
    end
  end

  guarded(id, function()
    local path = M.path(record)
    if not path then
      return finished(id)
    end
    if vim.fn.executable "claude" == 0 then
      warn_once(record, "claude isn't on PATH")
      return finished(id)
    end
    M.latest_turn(record.transcript_path, function(turn)
      vim.schedule(guarded(id, function()
        ask(path, turn)
      end))
    end)
  end)()
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
    if keeps(live) then
      run(live)
    else
      tab.running = false
    end
  end, delay)
end

-- Called by lua/floatterm/claude when a tab's Claude finishes a turn.
function M.on_stop(record)
  if keeps(record) then
    start(record, SETTLE_MS)
  end
end

-- Rewrites the notes from the latest turn now. `record` defaults to the tab showing.
function M.refresh(record)
  local floatterm = require "floatterm"
  record = record or floatterm.record(floatterm.current_buf() or -1)
  if not settings.get "claude_notes" then
    vim.notify("Claude's notes: switched off in the settings", vim.log.levels.WARN)
  elseif not (record and record.kind == "claude") then
    vim.notify("Claude's notes: not a Claude tab", vim.log.levels.WARN)
  elseif not (record.notes_on and record.note_id) then
    vim.notify("Claude's notes: this tab's notes are off", vim.log.levels.WARN)
  elseif not record.transcript_path then
    vim.notify("Claude's notes: no conversation yet", vim.log.levels.WARN)
  elseif not keeps(record) then
    vim.notify("Claude's notes: an earlier tab with these notes keeps them up to date", vim.log.levels.WARN)
  else
    start(record, 0)
  end
end

-- A closed tab's run state goes with it.
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("floatterm_claude_notes", { clear = true }),
  pattern = "FloatTermTabsChanged",
  callback = function()
    for id in pairs(state) do
      if not find(id) then
        state[id] = nil
      end
    end
  end,
})

-- For tests.
M.turn_from = turn_from
M.redact = redact
M.state = state

return M
