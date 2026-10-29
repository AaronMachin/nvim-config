-- What each floating-terminal tab's Claude is doing, from Claude Code's hooks.
--
-- bin/floatterm-claude-hook (installed into ~/.claude/settings.json by
-- install-claude-hooks.sh) runs for every hook event and, inside a floatterm tab,
-- calls M.hook here with the tab's id, a file holding the event's JSON and Claude's
-- pid (M.tool_used for PostToolUse, which needs no JSON). The tab's record changes
-- through floatterm.update, so the tab bar and anything else listening to
-- FloatTermTabChanged sees it:
--   SessionStart      kind = "claude" with its session_id. A `claude` typed in a
--                     shell tab makes it a Claude tab this way
--   UserPromptSubmit  status = "working", last_prompt = the prompt's first line
--   Notification      status = "needs_you" and needs_you_message = what it asks, with
--                     a notification saying so, when Claude asks a question or for
--                     permission
--   PostToolUse       status back to "working" from "needs_you", as a tool only runs
--                     once the question was answered
--   Stop              status = "done"
-- needs_you_message goes whenever the status moves on from "needs_you".
--   SessionEnd        back to a shell tab, for when Claude exits and its shell stays
-- A key pressed in a needs-you tab's terminal also takes it to "working" at once, as
-- answering (approving, or Esc) always takes a key.
--
-- Only the Claude started directly in the tab counts: the tab's job itself, or a
-- child of the tab's shell (`claude` typed there). Anything Claude runs inherits the
-- tab's variables, so a `claude -p` it starts reports here too, and is ignored. That
-- Claude's pid is kept as claude_pid; if it's gone without a SessionEnd (killed), the
-- tab goes back to being a shell tab within CHECK_EVERY.

local M = {}

-- Notification types that mean Claude is waiting on an answer. Others (idle_prompt
-- after it has finished, auth_success, agent_completed) aren't asks.
local ASKS = {
  permission_prompt = true,
  elicitation_dialog = true,
  elicitation_url_dialog = true,
  agent_needs_input = true,
}

local PROMPT_LENGTH = 80
local CHECK_EVERY = 5000

-- What SessionEnd clears from a record, besides start_ref (kept over a /clear).
local CLAUDE_FIELDS = {
  "status",
  "status_since",
  "needs_you_message",
  "session_id",
  "transcript_path",
  "last_prompt",
  "shell_title",
  "claude_pid",
}

local timer = nil

local function find(id)
  for _, record in ipairs(require("floatterm").tabs()) do
    if record.id == id then
      return record
    end
  end
  return nil
end

-- A value from the event's JSON as text: strings without NULs (which Vimscript
-- functions take as a Blob and refuse), numbers as written, anything else empty.
local function text(value)
  if type(value) == "number" then
    return tostring(value)
  end
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%z", ""))
end

local function first_line(prompt)
  local line = vim.trim(text(prompt):match "^%s*([^\n]*)" or "")
  if vim.fn.strchars(line) > PROMPT_LENGTH then
    line = vim.fn.strcharpart(line, 0, PROMPT_LENGTH - 1) .. "…"
  end
  return line
end

-- The process `pid` as { name, pid, ppid }, or nil when there's no such process.
local function process(pid)
  local ok, found = pcall(vim.api.nvim_get_proc, pid)
  return ok and found or nil
end

-- Whether `pid` is the Claude started directly in the tab: its job, or a child of its
-- shell. A tab opened as Claude (agent.open) only counts its job, as its own children
-- are whatever that Claude runs.
local function started_in(record, pid)
  local ok, job = pcall(vim.fn.jobpid, record.job)
  if not (ok and job and job > 0 and pid) then
    return false
  end
  if pid == job then
    return true
  end
  if record.claude_job then
    return false
  end
  local found = process(pid)
  return found ~= nil and found.ppid == job
end

-- Whether to take an event from the Claude with `pid`. While the tab's Claude is
-- still running, another started in the same shell (behind it with &, say) isn't.
local function accepts(record, pid)
  if not started_in(record, pid) then
    return false
  end
  local known = record.claude_pid
  return not known or known == pid or not started_in(record, known)
end

-- Makes a Claude tab a shell tab again. start_ref goes too unless `keep_start_ref`.
local function to_shell(record, keep_start_ref)
  local shell = { kind = "shell" }
  for _, key in ipairs(CLAUDE_FIELDS) do
    shell[key] = vim.NIL
  end
  if not keep_start_ref then
    shell.start_ref = vim.NIL
  end
  require("floatterm").update(record.buf, shell)
end

local function stop_watching()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Every CHECK_EVERY, while some tab has a Claude pid: a tab whose Claude has gone
-- without a SessionEnd (killed) becomes a shell tab again. Stops when none is left.
local function check()
  local watched = 0
  for _, record in ipairs(require("floatterm").tabs()) do
    if record.kind == "claude" and record.claude_pid then
      if started_in(record, record.claude_pid) then
        watched = watched + 1
      else
        to_shell(record)
      end
    end
  end
  if watched == 0 then
    stop_watching()
  end
end

local function watch()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(
    CHECK_EVERY,
    CHECK_EVERY,
    vim.schedule_wrap(function()
      pcall(check)
    end)
  )
end

-- The commit Claude started on, for agent.review. Only set once per Claude run, so
-- a /clear keeps reviewing from where the tab's Claude first started.
local function record_start_ref(record)
  if record.start_ref then
    return
  end
  vim.system({ "git", "rev-parse", "HEAD" }, { cwd = record.cwd, text = true }, function(result)
    if result.code == 0 then
      vim.schedule(function()
        require("floatterm").update(record.buf, { start_ref = vim.trim(result.stdout) })
      end)
    end
  end)
end

-- Applies a hook event to a tab. `pid` is the Claude it came from (nil from tests),
-- kept on the record to notice that Claude going.
local function apply(record, event, pid)
  local floatterm = require "floatterm"
  local name = event.hook_event_name
  local session_id = type(event.session_id) == "string" and event.session_id or nil
  local claude = { kind = "claude", session_id = session_id, claude_pid = pid }

  if name == "SessionStart" then
    -- Where Claude runs is where `claude --resume` has to run to find the session,
    -- which may not be where the tab started if the user cd'd first.
    local cwd = type(event.cwd) == "string" and (vim.uv.fs_realpath(event.cwd) or event.cwd) or nil
    claude.cwd = cwd
    claude.transcript_path = type(event.transcript_path) == "string" and event.transcript_path or nil
    -- The shell's own title (user@host:path) is still there until Claude sets one;
    -- the tab bar mustn't show it as what Claude is working on. Only when the tab was a
    -- shell a moment ago, and the title doesn't look like Claude's (which starts with
    -- a symbol such as ✳): a resumed Claude has already set its summary by now.
    local title = vim.b[record.buf].term_title
    local looks_like_claude = type(title) == "string" and not title:match "^[%w%s]"
    if record.kind == "shell" and title and not looks_like_claude then
      claude.shell_title = title
    end
    floatterm.update(record.buf, claude)
    record_start_ref(record)
  elseif name == "UserPromptSubmit" then
    claude.status = "working"
    claude.needs_you_message = vim.NIL
    claude.last_prompt = first_line(event.prompt)
    floatterm.update(record.buf, claude)
  elseif name == "Notification" then
    if event.notification_type and not ASKS[event.notification_type] then
      return
    end
    local message = vim.trim(text(event.message))
    claude.status = "needs_you"
    -- One line, for the notes pane to show above the status bar.
    claude.needs_you_message = (message:gsub("%s+", " "))
    floatterm.update(record.buf, claude)
    vim.notify("✳ " .. floatterm.name(record) .. " needs you: " .. (message ~= "" and message or "Claude is waiting"))
  elseif name == "PostToolUse" then
    if record.status == "needs_you" then
      floatterm.update(record.buf, { status = "working", needs_you_message = vim.NIL })
    end
  elseif name == "Stop" then
    claude.status = "done"
    claude.needs_you_message = vim.NIL
    floatterm.update(record.buf, claude)
    pcall(function()
      require("floatterm.claude_notes").on_stop(record)
    end)
  elseif name == "SessionEnd" then
    to_shell(record, event.reason == "clear")
    return
  end

  if record.claude_pid then
    watch()
  end
end

-- Called by bin/floatterm-claude-hook through `nvim --server $NVIM --remote-expr`.
-- Reads the event now, since the script removes the file once this returns, and
-- applies it on the main loop so the script isn't kept waiting.
function M.hook(tab_id, path, pid)
  local file = io.open(path, "r")
  if not file then
    return
  end
  local text_read = file:read "*a"
  file:close()
  os.remove(path)

  local ok, event = pcall(vim.json.decode, text_read, { luanil = { object = true } })
  if not ok or type(event) ~= "table" then
    return
  end
  tab_id = tonumber(tab_id)
  pid = tonumber(pid)

  vim.schedule(function()
    local record = find(tab_id)
    if record and accepts(record, pid) then
      apply(record, event, pid)
    end
  end)
end

-- The hook's call for PostToolUse, without the event's JSON (it holds the tool's
-- whole output, and all it changes is a "needs you").
function M.tool_used(tab_id, pid)
  tab_id = tonumber(tab_id)
  pid = tonumber(pid)
  vim.schedule(function()
    local record = find(tab_id)
    if record and accepts(record, pid) then
      apply(record, { hook_event_name = "PostToolUse" }, pid)
    end
  end)
end

-- Mouse and focus events reach the terminal too, but aren't an answer.
local function answers(key)
  local name = vim.fn.keytrans(key)
  return name ~= ""
    and not (
      name:find "Mouse"
      or name:find "ScrollWheel"
      or name:find "Drag"
      or name:find "Release"
      or name:find "Focus"
    )
end

-- Watches what's typed in terminal mode for a key in a tab whose Claude needs you.
-- Runs for every key, so it only looks until it knows the key isn't one.
vim.on_key(function(key, typed)
  if vim.api.nvim_get_mode().mode ~= "t" then
    return
  end
  local floatterm = package.loaded["floatterm"]
  local buf = vim.api.nvim_get_current_buf()
  local record = floatterm and floatterm.record(buf)
  if not (record and record.status == "needs_you" and answers(typed ~= nil and typed ~= "" and typed or key)) then
    return
  end
  -- Nothing can change while a key is being handled.
  vim.schedule(function()
    local now = floatterm.record(buf)
    if now and now.status == "needs_you" then
      floatterm.update(buf, { status = "working", needs_you_message = vim.NIL })
    end
  end)
end, vim.api.nvim_create_namespace "floatterm_claude_answered")

-- For tests: applies an event as if the hook had sent it, and runs the check for
-- killed Claudes now.
M.apply = apply
M.check = check

return M
