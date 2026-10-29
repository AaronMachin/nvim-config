-- Claude's half of a Claude tab's notes: a short sheet kept up to date by a small,
-- cheap Claude (the claude_notes_model setting, haiku by default) after each turn.
-- The claude_notes setting switches it off everywhere.
--
-- When the tab's Claude finishes a turn (the Stop hook, through lua/floatterm/claude)
-- and the tab has notes on, the turn is read from Claude Code's transcript (from the
-- last prompt to the end: the prompt, Claude's replies, and the tools it ran with a
-- short result) and given to `claude -p` with the current sheet, which it rewrites in
-- the user's shape: a summary with hashtags, a status bar with the tasks, PRs, key
-- links, details. Anything that looks like a secret
-- (tokens, keys, passwords) is replaced with [redacted] before it's sent; links are
-- kept, but for the values of parameters such as ?token= in them. Claude's
-- structured reply is written beside the user's own notes (floatterm.notes.paths) as
-- <note_id>.claude.json, which the pane draws at its own width, and the sheet as
-- <note_id>.claude.md at a fixed width, for Claude in the tab to read and as the next
-- run's current sheet. FloatTermClaudeNotesChanged is then fired with the note_id so the
-- pane can reload it. The percentage is worked out from the tasks, not asked for.
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
You keep a short notes sheet for a developer about a Claude Code session running in one of their terminal tabs. You are given the current sheet and the latest turn of the session: the user's prompt, Claude's replies, and the tools Claude ran with short results. Reply with the updated sheet as data in the given schema:

- summary: one or two short lines on what this session is about and where it is. Simple, key words.
- hashtags: up to 10 one-word categories for the session (no # needed), e.g. auth, cognito, deploy.
- tasks: the session's plan as tasks, in order, each with a short name and a state (done, in_progress, pending, blocked), and for in_progress or blocked a few words on what it is doing or what blocks it. Keep the tasks and their names stable between turns unless the work changed.
- prs: every pull request mentioned, with its full URL and a few words.
- links: other links worth reopening (Jira, docs, dashboards, deploys), with full URLs and a few words.
- details: anything else worth keeping, as terse lines: decisions and why, branch and commits, what's waiting on whom.

Keep what is still true from the current sheet, update what this turn changed, and drop what is stale or routine. Never invent a link or a task that isn't in the input. Keep details to about 10 lines. UK English.]]

-- The shape Claude has to reply in (claude -p --json-schema), so the sheet's layout is
-- drawn here and can't drift: the bar, the task tree and the links are always right.
local SCHEMA = {
  type = "object",
  properties = {
    summary = { type = "string" },
    hashtags = { type = "array", items = { type = "string" }, maxItems = 10 },
    tasks = {
      type = "array",
      items = {
        type = "object",
        properties = {
          name = { type = "string" },
          state = { type = "string", enum = { "done", "in_progress", "pending", "blocked" } },
          detail = { type = "string" },
        },
        required = { "name", "state" },
      },
    },
    prs = {
      type = "array",
      items = {
        type = "object",
        properties = { url = { type = "string", pattern = "^https?://" }, title = { type = "string" } },
        required = { "url", "title" },
      },
    },
    links = {
      type = "array",
      items = {
        type = "object",
        properties = { url = { type = "string", pattern = "^https?://" }, title = { type = "string" } },
        required = { "url", "title" },
      },
    },
    details = { type = "array", items = { type = "string" } },
  },
  required = { "summary", "hashtags", "tasks", "prs", "links", "details" },
}

local STATES = {
  done = { "🟢", "DONE" },
  in_progress = { "🔵", "IN PROGRESS" },
  pending = { "⚪", "PENDING" },
  blocked = { "🔴", "BLOCKED" },
}
-- What each task counts for in the percentage: half for one under way.
local WORTH = { done = 1, in_progress = 0.5 }
-- The .md is read by Claude in the tab and given to the next run, not drawn in a pane,
-- so it gets a fixed width.
local DEFAULT_WIDTH = 42
local MIN_BAR = 10
-- More tasks than this and the done ones fold into one line, so the current and next
-- ones stay in view. Still more, and the last ones become a count, so no more than
-- this many task rows show.
local FOLD_OVER = 6
local NEEDS_YOU_HL = "FloatTermNeedsYou"

local function text(value)
  return type(value) == "string" and vim.trim(value) or ""
end

-- On one line: only the summary may span lines.
local function one_line(value)
  return (text(value):gsub("%s*\n%s*", " "))
end

local function width_of(s)
  return vim.fn.strdisplaywidth(s)
end

-- `s` cut to `width` cells, ending in … when it was cut.
local function fit(s, width)
  if width_of(s) <= width then
    return s
  end
  local out = ""
  for _, char in ipairs(vim.fn.split(s, "\\zs")) do
    if width_of(out .. char) + 1 > width then
      break
    end
    out = out .. char
  end
  return out .. "…"
end

-- Rounded down, so 100% only once everything is done.
local function percent_of(tasks)
  local sum = 0
  for _, task in ipairs(tasks) do
    sum = sum + (WORTH[task.state] or 0)
  end
  return math.floor(sum * 100 / #tasks)
end

-- The line shown above the bar while the tab's Claude waits on you.
function M.needs_you_line(message)
  message = text(message):gsub("%s+", " ")
  return "● Needs you" .. (message ~= "" and (": " .. message) or ""), NEEDS_YOU_HL
end

-- The sheet in the user's shape, from Claude's structured reply, as lines and their
-- highlights ({ line, col, end_col, group }, 0-based bytes). opts:
--   width      the text width to fit the bar and task names in (DEFAULT_WIDTH)
--   needs_you  the notification message (or "") when the tab's Claude is waiting on you
function M.render(data, opts)
  opts = opts or {}
  local width = math.max(1, opts.width or DEFAULT_WIDTH)
  local lines, highlights = { "# Summary of chat" }, {}
  if text(data.summary) ~= "" then
    table.insert(lines, text(data.summary))
  end
  local function highlight(col, end_col, group)
    table.insert(highlights, { line = #lines - 1, col = col, end_col = end_col, group = group })
  end
  local tags = {}
  for _, tag in ipairs(type(data.hashtags) == "table" and data.hashtags or {}) do
    tag = text(tag):gsub("^#+", ""):gsub("%s+", "-")
    if tag ~= "" and #tags < 10 then
      table.insert(tags, "#" .. tag)
    end
  end
  if #tags > 0 then
    table.insert(lines, table.concat(tags, " "))
  end

  local tasks = vim.tbl_filter(function(task)
    return type(task) == "table" and text(task.name) ~= ""
  end, type(data.tasks) == "table" and data.tasks or {})
  tasks = vim.tbl_map(function(task)
    return { name = one_line(task.name), state = task.state, detail = one_line(task.detail) }
  end, tasks)
  if #tasks > 0 or opts.needs_you then
    vim.list_extend(lines, { "", "# Status" })
  end
  if opts.needs_you then
    local line, group = M.needs_you_line(opts.needs_you)
    table.insert(lines, line)
    highlight(0, #line, group)
  end
  if #tasks > 0 then
    local percent = percent_of(tasks)
    local label = (" %d%%"):format(percent)
    local cells = math.max(MIN_BAR, width - 2 - #label)
    local filled = math.floor(cells * percent / 100)
    local full, empty = string.rep("█", filled), string.rep("░", cells - filled)
    local colour = "DiagnosticOk"
    for _, task in ipairs(tasks) do
      if task.state == "blocked" then
        colour = "DiagnosticError"
        break
      elseif task.state == "in_progress" then
        colour = "DiagnosticInfo"
      end
    end
    table.insert(lines, "[" .. full .. empty .. "]" .. label)
    highlight(1, 1 + #full, colour)
    highlight(1 + #full, 1 + #full + #empty, "Comment")

    local shown, folded, more = tasks, 0, 0
    if #tasks > FOLD_OVER then
      shown = vim.tbl_filter(function(task)
        return task.state ~= "done"
      end, tasks)
      folded = #tasks - #shown
      -- Room for the folded line and the count, the rest for the first tasks left.
      local room = FOLD_OVER - (folded > 0 and 1 or 0)
      if #shown > room then
        more = #shown - (room - 1)
        shown = vim.list_slice(shown, 1, room - 1)
      end
    end
    -- Names are cut so every state starts in one column inside the width: 8 cells for
    -- "  ├─ 🟢 ", a space each side of the dots, at least 2 dots (6 when there's room).
    local widest, longest_state = 0, 0
    for _, task in ipairs(shown) do
      widest = math.max(widest, width_of(text(task.name)))
      longest_state = math.max(longest_state, width_of((STATES[task.state] or STATES.pending)[2]))
    end
    local room = width - 10 - longest_state
    local least_dots = math.max(2, math.min(6, room - widest))
    local column = math.max(1, math.min(widest, room - least_dots))

    local rows = {}
    if folded > 0 then
      table.insert(rows, ("%s %d done"):format(STATES.done[1], folded))
    end
    for _, task in ipairs(shown) do
      local state = STATES[task.state] or STATES.pending
      local name = fit(task.name, column)
      local dots = string.rep(".", column - width_of(name) + least_dots)
      local row = ("%s %s %s %s"):format(state[1], name, dots, state[2])
      if (task.state == "in_progress" or task.state == "blocked") and task.detail ~= "" then
        -- Drawn in a pane, the detail is cut to what's left of the width ("  ├─ " goes
        -- before the row) so the row doesn't wrap. The .md keeps it whole for Claude.
        local left = width - 5 - width_of(row) - 3
        if not opts.width then
          row = row .. " (" .. task.detail .. ")"
        elseif left >= 2 then
          row = row .. " (" .. fit(task.detail, left) .. ")"
        end
      end
      table.insert(rows, row)
    end
    if more > 0 then
      table.insert(rows, ("… %d more"):format(more))
    end
    for i, row in ipairs(rows) do
      table.insert(lines, ("  %s %s"):format(i == #rows and "└─" or "├─", row))
    end
  end

  -- Only entries with a real URL: a link without one isn't worth showing.
  local function link_section(heading, entries)
    local items = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
      local url = type(entry) == "table" and text(entry.url) or ""
      if url:match "^https?://" then
        local title = one_line(entry.title)
        table.insert(items, "- " .. (title ~= "" and (title .. ": ") or "") .. url)
      end
    end
    if #items > 0 then
      vim.list_extend(lines, { "", heading })
      vim.list_extend(lines, items)
    end
  end
  link_section("# PRs", data.prs)
  link_section("# Key links", data.links)

  local details = {}
  for _, line in ipairs(type(data.details) == "table" and data.details or {}) do
    if text(line) ~= "" then
      table.insert(details, "- " .. one_line(line):gsub("^[-*]%s*", ""))
    end
  end
  if #details > 0 then
    vim.list_extend(lines, { "", "# Details" })
    vim.list_extend(lines, details)
  end
  return lines, highlights
end

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
  return record
    and record.kind == "claude"
    and record.notes_on
    and record.note_id
    and record.transcript_path
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

-- Where Claude's structured reply is kept beside the sheet at `path` (the .claude.md),
-- for the pane to draw at its own width.
function M.data_path(path)
  return (path:gsub("%.md$", ".json"))
end

local REDACTED = "[redacted]"

-- Key names whose values are secrets: password, passwd or secret anywhere in the name,
-- or ending in token or api key (so max_tokens is kept).
local function secret_name(name)
  name = name:lower()
  return name:find "password"
    or name:find "passwd"
    or name:find "secret"
    or name:find "token$"
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
  return (
    text:gsub("(%-%-([%w_%-]+)%s+)([^%s%-][^%s]*)", function(flag, name)
      if secret_name(name) then
        return flag .. REDACTED
      end
    end)
  )
end

-- Query (or fragment) parameters whose values are secrets, by a word in their name.
local SECRET_PARAMS = { "token", "key", "secret", "password", "passwd", "signature" }

-- A link kept whole but for the values of its secret parameters (?token=, a signed
-- URL's signature), as a document's or design's id looks like a random key.
local function redact_url(url)
  return (
    url:gsub("([?&;#])([^=&;#]+)=([^&;#]*)", function(sep, name, value)
      local lower = name:lower()
      for _, word in ipairs(SECRET_PARAMS) do
        if value ~= "" and lower:find(word, 1, true) then
          return sep .. name .. "=" .. REDACTED
        end
      end
    end)
  )
end

-- Replaces anything that looks like a secret with [redacted]: private keys, auth
-- headers and bearer tokens, password/secret/token/api key values, AWS, GitHub and
-- Slack keys, JWTs and long random strings. Links are set aside first and put back
-- after, whole but for secret parameters. Only ever sees text on its way to Claude.
local function redact(text)
  local urls = {}
  text = text:gsub("https?://[^%s\"'<>\\`]+", function(url)
    table.insert(urls, redact_url(url))
    return "\1" .. #urls .. "\2"
  end)
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
  text = text:gsub("\1(%d+)\2", function(n)
    return urls[tonumber(n)]
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
    -- The structured reply, drawn in the user's shape; the plain text only if a reply
    -- somehow came back without it.
    local data = type(out.structured_output) == "table" and out.structured_output or nil
    local sheet = data and table.concat((M.render(data)), "\n") or sheet_from(out.result)
    -- The path again, from the note the run started with, not whatever the tab has now.
    local path = M.path { note_id = note_id }
    if sheet ~= "" and path and may_write(id, note_id) then
      local written, write_err = true, nil
      if data then
        written, write_err = write_atomically(M.data_path(path), vim.json.encode(data) .. "\n")
      else
        -- The pane draws from the .json when there is one, which would now be older.
        os.remove(M.data_path(path))
      end
      if written then
        written, write_err = write_atomically(path, sheet .. "\n")
      end
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
      "--json-schema",
      vim.json.encode(SCHEMA),
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
