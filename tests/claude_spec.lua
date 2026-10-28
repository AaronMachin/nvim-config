-- lua/floatterm/claude: Claude Code's hook events turned into tab record fields, and
-- which Claude's events a tab takes (only the one started directly in it).

local H = require "test_helpers"
local api = vim.api

local ft, claude

-- The process ids under `pid`, children first then theirs.
local function descendants(pid)
  local found = {}
  for _, child in ipairs(api.nvim_get_proc_children(pid)) do
    table.insert(found, child)
    vim.list_extend(found, descendants(child))
  end
  return found
end

local function job_pid(buf)
  return vim.fn.jobpid(ft.record(buf).job)
end

local function send(buf, event, pid)
  local path = H.write(H.tmpdir "hook" .. "/event.json", vim.json.encode(event))
  claude.hook(tostring(ft.record(buf).id), path, pid and tostring(pid) or nil)
  return path
end

describe("claude hooks", function()
  local buf, messages

  before_each(function()
    H.isolate()
    ft = require "floatterm"
    claude = require "floatterm.claude"
    H.isolate()
    buf = H.sleep_tab { label = "app" }
    messages = H.capture_notify()
    -- Claude's notes run after Stop; not here.
    H.stub(require "floatterm.claude_notes", "on_stop", function() end)
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  describe("events to record fields", function()
    local record

    before_each(function()
      record = ft.record(buf)
    end)

    it("SessionStart makes a shell tab a Claude tab with its session", function()
      local dir = H.tmpdir "where-claude-runs"
      claude.apply(record, {
        hook_event_name = "SessionStart",
        session_id = "abc",
        cwd = dir,
        transcript_path = "/tmp/abc.jsonl",
      })
      assert.equals("claude", record.kind)
      assert.equals("abc", record.session_id)
      assert.equals(dir, record.cwd)
      assert.equals("/tmp/abc.jsonl", record.transcript_path)
    end)

    it("keeps the shell's own title aside so the bar doesn't show it as Claude's task", function()
      vim.b[buf].term_title = "me@host:~/app"
      claude.apply(record, { hook_event_name = "SessionStart", session_id = "a" })
      assert.equals("me@host:~/app", record.shell_title)
    end)

    it("doesn't take a resumed Claude's own summary for the shell's title", function()
      vim.b[buf].term_title = "✳ Fixing the login"
      claude.apply(record, { hook_event_name = "SessionStart", session_id = "a" })
      assert.is_nil(record.shell_title)
      -- Nor for a tab that was already Claude's.
      vim.b[buf].term_title = "me@host:~/app"
      claude.apply(record, { hook_event_name = "SessionStart", session_id = "b" })
      assert.is_nil(record.shell_title)
    end)

    it("UserPromptSubmit: working, with the prompt's first line cut to 80", function()
      record.needs_you_message = "old"
      claude.apply(record, { hook_event_name = "UserPromptSubmit", prompt = "\n  " .. string.rep("x", 100) .. "\nmore" })
      assert.equals("working", record.status)
      assert.equals(80, vim.fn.strchars(record.last_prompt))
      assert.truthy(record.last_prompt:find("…$"))
      assert.is_nil(record.needs_you_message)
    end)

    it("Notification asking for permission: needs you, with the message on one line", function()
      claude.apply(record, {
        hook_event_name = "Notification",
        notification_type = "permission_prompt",
        message = "Claude needs your\n  permission to use Bash",
      })
      assert.equals("needs_you", record.status)
      assert.equals("Claude needs your permission to use Bash", record.needs_you_message)
      assert.is_not_nil(H.notified(messages, "app needs you"))
    end)

    it("ignores notifications that aren't asks", function()
      claude.apply(record, { hook_event_name = "UserPromptSubmit", prompt = "hi" })
      claude.apply(record, { hook_event_name = "Notification", notification_type = "idle_prompt", message = "waiting" })
      assert.equals("working", record.status)
      assert.is_nil(record.needs_you_message)
    end)

    it("PostToolUse after a question goes back to working and drops the question", function()
      claude.apply(record, { hook_event_name = "Notification", message = "Allow?" })
      claude.apply(record, { hook_event_name = "PostToolUse" })
      assert.equals("working", record.status)
      assert.is_nil(record.needs_you_message)
      -- From done it changes nothing.
      claude.apply(record, { hook_event_name = "Stop" })
      claude.apply(record, { hook_event_name = "PostToolUse" })
      assert.equals("done", record.status)
    end)

    it("Stop: done, the question gone, and Claude's notes told", function()
      local stopped = nil
      H.stub(require "floatterm.claude_notes", "on_stop", function(r)
        stopped = r
      end)
      claude.apply(record, { hook_event_name = "Notification", message = "Allow?" })
      claude.apply(record, { hook_event_name = "Stop" })
      assert.equals("done", record.status)
      assert.is_nil(record.needs_you_message)
      assert.equals(record, stopped)
    end)

    it("SessionEnd makes it a shell tab again, keeping start_ref only over a /clear", function()
      claude.apply(record, { hook_event_name = "SessionStart", session_id = "a", transcript_path = "/t" })
      claude.apply(record, { hook_event_name = "UserPromptSubmit", prompt = "hi" })
      ft.update(buf, { start_ref = "abc123" })
      claude.apply(record, { hook_event_name = "SessionEnd", reason = "clear" })
      assert.equals("shell", record.kind)
      assert.equals("abc123", record.start_ref)
      for _, field in ipairs { "status", "session_id", "transcript_path", "last_prompt", "claude_pid" } do
        assert.is_nil(record[field], field)
      end
      claude.apply(record, { hook_event_name = "SessionEnd", reason = "logout" })
      assert.is_nil(record.start_ref)
    end)
  end)

  describe("which Claude counts", function()
    it("takes events from the tab's own job, through the hook file, and removes the file", function()
      local path = send(buf, { hook_event_name = "UserPromptSubmit", prompt = "hello" }, job_pid(buf))
      assert.is_false(H.exists(path))
      H.wait(1000, function()
        return ft.record(buf).status == "working"
      end)
      assert.equals(job_pid(buf), ft.record(buf).claude_pid)
    end)

    it("takes a claude typed in the tab's shell (a child of it)", function()
      local _, shell = ft.new_tab { "sh", "-c", "sleep 300 & wait" }
      H.wait(2000, function()
        return #descendants(job_pid(shell)) > 0
      end)
      local child = descendants(job_pid(shell))[1]
      send(shell, { hook_event_name = "SessionStart", session_id = "typed" }, child)
      H.wait(1000, function()
        return ft.record(shell).kind == "claude"
      end)
      assert.equals("typed", ft.record(shell).session_id)
    end)

    it("ignores a nested claude (one the tab's Claude started)", function()
      local _, shell = ft.new_tab { "sh", "-c", "sh -c 'sleep 300; true' & wait" }
      H.wait(2000, function()
        return #descendants(job_pid(shell)) >= 2
      end)
      local grandchild = descendants(job_pid(shell))[2]
      send(shell, { hook_event_name = "SessionStart", session_id = "nested" }, grandchild)
      H.flush(200)
      assert.equals("shell", ft.record(shell).kind)
      -- Nor nvim itself, nor an event with no pid at all.
      send(shell, { hook_event_name = "SessionStart", session_id = "x" }, vim.fn.getpid())
      send(shell, { hook_event_name = "SessionStart", session_id = "x" }, nil)
      H.flush(200)
      assert.equals("shell", ft.record(shell).kind)
    end)

    it("ignores a second Claude in the same shell while the first is running", function()
      local _, shell = ft.new_tab { "sh", "-c", "sleep 300 & sleep 300 & wait" }
      H.wait(2000, function()
        return #descendants(job_pid(shell)) >= 2
      end)
      local first, second = unpack(descendants(job_pid(shell)))
      send(shell, { hook_event_name = "SessionStart", session_id = "first" }, first)
      H.wait(1000, function()
        return ft.record(shell).session_id == "first"
      end)
      send(shell, { hook_event_name = "SessionStart", session_id = "second" }, second)
      H.flush(200)
      assert.equals("first", ft.record(shell).session_id)
    end)

    it("only counts the job itself in a tab opened as Claude", function()
      local _, tab = ft.new_tab({ "sh", "-c", "sleep 300 & wait" }, { kind = "claude" })
      ft.update(tab, { claude_job = true })
      H.wait(2000, function()
        return #descendants(job_pid(tab)) > 0
      end)
      send(tab, { hook_event_name = "UserPromptSubmit", prompt = "x" }, descendants(job_pid(tab))[1])
      H.flush(200)
      assert.is_nil(ft.record(tab).status)
    end)

    it("turns a tab whose Claude was killed back into a shell", function()
      local _, shell = ft.new_tab { "sh", "-c", "sleep 1 & wait; sleep 300; true" }
      H.wait(2000, function()
        return #descendants(job_pid(shell)) > 0
      end)
      local short = descendants(job_pid(shell))[1]
      send(shell, { hook_event_name = "SessionStart", session_id = "s" }, short)
      H.wait(1000, function()
        return ft.record(shell).kind == "claude"
      end)
      -- The shell reaps it, so it's gone rather than left a zombie.
      H.wait(3000, function()
        return not vim.tbl_contains(descendants(job_pid(shell)), short)
      end)
      claude.check()
      assert.equals("shell", ft.record(shell).kind)
    end)
  end)
end)
