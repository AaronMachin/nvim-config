-- What each floating-terminal tab's Claude is doing, from Claude Code's hooks.
--
-- bin/floatterm-claude-hook (installed into ~/.claude/settings.json by
-- install-claude-hooks.sh) runs for every hook event and, inside a floatterm tab,
-- calls M.hook here with the tab's id and a file holding the event's JSON. The tab's
-- record changes through floatterm.update, so the tab bar and anything else
-- listening to FloatTermTabChanged sees it:
--   SessionStart      kind = "claude" with its session_id. A `claude` typed in a
--                     shell tab makes it a Claude tab this way
--   UserPromptSubmit  status = "working", last_prompt = the prompt's first line
--   Notification      status = "needs_you", with a notification saying so, when
--                     Claude asks a question or for permission
--   Stop              status = "done"
--   SessionEnd        back to a shell tab, for when Claude exits and its shell stays

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

local function find(id)
  for _, record in ipairs(require("floatterm").tabs()) do
    if record.id == id then
      return record
    end
  end
  return nil
end

local function first_line(prompt)
  local line = vim.trim((prompt or ""):match "^%s*([^\n]*)" or "")
  if vim.fn.strchars(line) > PROMPT_LENGTH then
    line = vim.fn.strcharpart(line, 0, PROMPT_LENGTH - 1) .. "…"
  end
  return line
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

local function apply(record, event)
  local floatterm = require "floatterm"
  local name = event.hook_event_name
  local claude = { kind = "claude", session_id = event.session_id }

  if name == "SessionStart" then
    -- Where Claude runs is where `claude --resume` has to run to find the session,
    -- which may not be where the tab started if the user cd'd first.
    local cwd = event.cwd and (vim.uv.fs_realpath(event.cwd) or event.cwd)
    claude.cwd = cwd
    claude.transcript_path = event.transcript_path
    -- The shell's own title (user@host:path) is still there until Claude sets one;
    -- the tab bar mustn't show it as what Claude is working on.
    claude.shell_title = vim.b[record.buf].term_title or vim.NIL
    floatterm.update(record.buf, claude)
    record_start_ref(record)
  elseif name == "UserPromptSubmit" then
    claude.status = "working"
    claude.last_prompt = first_line(event.prompt)
    floatterm.update(record.buf, claude)
  elseif name == "Notification" then
    if event.notification_type and not ASKS[event.notification_type] then
      return
    end
    claude.status = "needs_you"
    floatterm.update(record.buf, claude)
    vim.notify("✳ " .. floatterm.name(record) .. " needs you: " .. (event.message or "Claude is waiting"))
  elseif name == "Stop" then
    claude.status = "done"
    floatterm.update(record.buf, claude)
  elseif name == "SessionEnd" then
    local shell = { kind = "shell" }
    for _, key in ipairs { "status", "status_since", "session_id", "transcript_path", "last_prompt", "shell_title" } do
      shell[key] = vim.NIL
    end
    if event.reason ~= "clear" then
      shell.start_ref = vim.NIL
    end
    floatterm.update(record.buf, shell)
  end
end

-- Called by bin/floatterm-claude-hook through `nvim --server $NVIM --remote-expr`.
-- Reads the event now, since the script removes the file once this returns, and
-- applies it on the main loop so the script isn't kept waiting.
function M.hook(tab_id, path)
  local file = io.open(path, "r")
  if not file then
    return
  end
  local text = file:read "*a"
  file:close()
  os.remove(path)

  local ok, event = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok or type(event) ~= "table" then
    return
  end
  tab_id = tonumber(tab_id)

  vim.schedule(function()
    local record = find(tab_id)
    if record then
      apply(record, event)
    end
  end)
end

-- For tests: applies an event as if the hook had sent it.
M.apply = apply

return M
