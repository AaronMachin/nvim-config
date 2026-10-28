-- lua/floatterm/claude_notes: drawing the sheet, redacting secrets, reading the turn
-- from a transcript, and the run's guards, with a fake `claude` (never the real one).

local H = require "test_helpers"

local cn, ft, notes, settings

local function task(name, state, detail)
  return { name = name, state = state, detail = detail }
end

local function find_line(lines, pattern)
  for i, line in ipairs(lines) do
    if line:find(pattern) then
      return i, line
    end
  end
  return nil
end

describe("Claude's notes", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    notes = require "floatterm.notes"
    cn = require "floatterm.claude_notes"
    settings = require "floatterm.settings"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  describe("render", function()
    it("works the percentage out from the tasks, half for one under way, rounded down", function()
      local lines = cn.render { summary = "s", tasks = { task("a", "done"), task("b", "in_progress") } }
      local _, bar = find_line(lines, "^%[")
      assert.truthy(bar:find " 75%%$")
      lines = cn.render { summary = "s", tasks = { task("a", "done"), task("b", "pending"), task("c", "blocked") } }
      _, bar = find_line(lines, "^%[")
      assert.truthy(bar:find " 33%%$")
    end)

    it("draws the bar to the width it's given, with a minimum", function()
      local data = { summary = "s", tasks = { task("a", "done"), task("b", "pending") } }
      local _, bar = find_line(cn.render(data, { width = 60 }), "^%[")
      assert.equals(60, vim.fn.strdisplaywidth(bar))
      _, bar = find_line(cn.render(data), "^%[")
      assert.equals(42, vim.fn.strdisplaywidth(bar))
      _, bar = find_line(cn.render(data, { width = 5 }), "^%[")
      assert.equals(10 + 2 + 4, vim.fn.strdisplaywidth(bar))
    end)

    it("colours the bar green, blue while one is under way, red if one is blocked", function()
      local function colour(tasks)
        local lines, highlights = cn.render { summary = "s", tasks = tasks }
        local row = find_line(lines, "^%[") - 1
        for _, hl in ipairs(highlights) do
          if hl.line == row and hl.col == 1 then
            return hl.group
          end
        end
      end
      assert.equals("DiagnosticOk", colour { task("a", "done") })
      assert.equals("DiagnosticInfo", colour { task("a", "done"), task("b", "in_progress") })
      assert.equals("DiagnosticError", colour { task("a", "in_progress"), task("b", "blocked") })
    end)

    it("folds done tasks into one line past six", function()
      local tasks = {}
      for i = 1, 4 do
        table.insert(tasks, task("done " .. i, "done"))
      end
      vim.list_extend(
        tasks,
        { task("now", "in_progress", "writing"), task("next", "pending"), task("later", "pending") }
      )
      local lines = cn.render { summary = "s", tasks = tasks }
      assert.is_not_nil(find_line(lines, "├─ 🟢 4 done$"))
      assert.is_nil(find_line(lines, "done 1"))
      local _, now = find_line(lines, " now ")
      assert.truthy(now:find("IN PROGRESS (writing)", 1, true))
      assert.is_not_nil(find_line(lines, "└─ ⚪ later"))
    end)

    it("cuts long task names so every state starts in one column", function()
      local lines = cn.render({
        summary = "s",
        tasks = { task(string.rep("very long task name ", 4), "done"), task("short", "pending") },
      }, { width = 42 })
      local _, long = find_line(lines, "…")
      local _, short = find_line(lines, "short")
      assert.is_true(vim.fn.strdisplaywidth(long) <= 42)
      local col = function(line, word)
        return vim.fn.strdisplaywidth(line:sub(1, line:find(word, 1, true) - 1))
      end
      assert.equals(col(long, "DONE"), col(short, "PENDING"))
    end)

    it("only lists links with a real URL, and leaves out an empty section", function()
      local lines = cn.render {
        summary = "s",
        prs = { { url = "https://github.com/o/r/pull/1", title = "the fix" }, { url = "PR 2", title = "no link" } },
        links = { { url = "ticket SD-1", title = "jira" } },
      }
      assert.is_not_nil(find_line(lines, "^%- the fix: https://github.com/o/r/pull/1$"))
      assert.is_nil(find_line(lines, "no link"))
      assert.is_nil(find_line(lines, "^# Key links"))
    end)

    it("shows what Claude is asking above the bar, and tidies hashtags", function()
      local lines, highlights = cn.render({
        summary = "s",
        hashtags = { "#auth", "two words" },
        tasks = { task("a", "pending") },
      }, { needs_you = "Allow   Bash?" })
      assert.equals("#auth #two-words", lines[3])
      local i = find_line(lines, "^● Needs you: Allow Bash%?$")
      assert.is_not_nil(i)
      assert.truthy(lines[i + 1]:find "^%[")
      assert.equals("FloatTermNeedsYou", highlights[1].group)
    end)
  end)

  describe("redaction", function()
    local cases = {
      { "password=hunter22", "password=[redacted]" },
      { 'DB_PASSWORD="two words"', 'DB_PASSWORD="[redacted]"' },
      { '{"api_key": "abc123"}', '{"api_key": "[redacted]"}' },
      { '{\\"github_token\\":\\"abc\\"}', '{\\"github_token\\":\\"[redacted]\\"}' },
      { "curl --token abcdef https://x", "curl --token [redacted] https://x" },
      { "https://x/?token=abc&page=2", "https://x/?token=[redacted]&page=2" },
      { "Authorization: Basic dXNlcjpwYXNz", "Authorization: [redacted]" },
      { "use Bearer abcdefgh12345 now", "use Bearer [redacted] now" },
      { "key AKIAABCDEFGHIJKLMNOP here", "key [redacted] here" },
      { "ghp_abcdefABCDEF0123456789", "[redacted]" },
      { "xoxb-123-456-abc", "[redacted]" },
      { "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc_def", "[redacted]" },
      { "-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----", "[redacted]" },
      { "key: " .. "aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dF3hJ5kL7nQ2", "key: [redacted]" },
    }
    for _, case in ipairs(cases) do
      it("redacts " .. case[1]:sub(1, 30), function()
        assert.equals(case[2], cn.redact(case[1]))
      end)
    end

    it("keeps things that only look a bit like secrets", function()
      for _, text in ipairs {
        "max_tokens=4096",
        "commit 3f2a9c4e5b6d7a8f9e0d1c2b3a4f5e6d7c8b9a0f",
        "feature/SD-501-backend-login-page-refresh",
        "/Users/someone/Projects/controlplane/app/Http/Controllers",
        "Bearer short",
      } do
        assert.equals(text, cn.redact(text))
      end
    end)
  end)

  describe("reading the turn", function()
    local function jsonl(entries)
      local out = {}
      for _, entry in ipairs(entries) do
        table.insert(out, vim.json.encode(entry))
      end
      return table.concat(out, "\n") .. "\n"
    end

    it("takes the last prompt and what followed, with tool results and secrets redacted", function()
      local text = jsonl {
        { type = "user", message = { content = "old prompt" } },
        { type = "user", gitBranch = "SD-1-x", message = { content = "deploy it, password=hunter22" } },
        {
          type = "assistant",
          message = {
            content = {
              { type = "text", text = "Deploying." },
              { type = "tool_use", id = "t1", name = "Bash", input = { command = "make deploy" } },
              { type = "tool_use", id = "t2", name = "Read", input = { file_path = "/x" } },
            },
          },
        },
        {
          type = "user",
          message = {
            content = {
              { type = "tool_result", tool_use_id = "t1", content = "done in 3s" },
              { type = "tool_result", tool_use_id = "t2", content = "file text" },
            },
          },
        },
        { type = "user", isMeta = true, message = { content = "skill text" } },
      }
      local turn = cn.turn_from(text)
      assert.truthy(turn:find("Branch: SD-1-x", 1, true))
      assert.truthy(turn:find("User: deploy it, password=[redacted]", 1, true))
      assert.truthy(turn:find("Claude: Deploying.", 1, true))
      assert.truthy(turn:find("$ make deploy", 1, true))
      assert.truthy(turn:find("-> ok: done in 3s", 1, true))
      assert.is_nil(turn:find("old prompt", 1, true))
      assert.is_nil(turn:find("file text", 1, true)) -- a Read is routine
    end)

    it("gives nothing without a prompt", function()
      assert.is_nil(
        cn.turn_from(jsonl { { type = "assistant", message = { content = { { type = "text", text = "hi" } } } } })
      )
    end)
  end)

  describe("the run", function()
    local bin, log, transcript

    -- The fake claude: logs its arguments, stdin and environment, waits $DELAY seconds
    -- (from a file, so a test can change it), then answers from reply.json and exits
    -- with the code in code.txt.
    local function fake_claude()
      bin = H.fake_bin()
      log = H.tmpdir "claude-log"
      H.write(log .. "/delay", "0")
      H.write(log .. "/code", "0")
      H.write(
        log .. "/reply.json",
        vim.json.encode {
          result = "ok",
          total_cost_usd = 0.001,
          structured_output = {
            summary = "Fixing login",
            hashtags = { "auth" },
            tasks = { { name = "fix", state = "done" } },
            prs = {},
            links = {},
            details = {},
          },
        }
      )
      H.script(
        bin,
        "claude",
        ([[
L=%q
echo run >>"$L/runs"
printf '%%s\n' "$@" >"$L/args"
echo "tab=[$FLOATTERM_TAB_ID]" >"$L/env"
cat >"$L/stdin"
sleep "$(cat "$L/delay")"
cat "$L/reply.json"
exit "$(cat "$L/code")"]]):format(log)
      )
    end

    local function claude_tab(fields)
      local buf = H.sleep_tab { kind = "claude" }
      ft.update(
        buf,
        vim.tbl_extend("force", {
          notes_on = true,
          note_id = "20261029-test",
          transcript_path = transcript,
        }, fields or {})
      )
      return ft.record(buf)
    end

    local function runs()
      local text = H.read(log .. "/runs") or ""
      return select(2, text:gsub("run", ""))
    end

    local function idle(record)
      H.wait(8000, function()
        return not (cn.state[record.id] and cn.state[record.id].running)
      end, "run didn't finish")
    end

    before_each(function()
      fake_claude()
      transcript = H.write(H.tmpdir "transcript" .. "/t.jsonl", vim.json.encode {
        type = "user",
        message = { content = "fix the login, token=abc123" },
      } .. "\n")
    end)

    it("writes the sheet and its data, tells the pane, and leaves no trace", function()
      local record = claude_tab()
      local changed = nil
      vim.api.nvim_create_autocmd("User", {
        pattern = "FloatTermClaudeNotesChanged",
        once = true,
        callback = function(args)
          changed = args.data.note_id
        end,
      })
      cn.refresh(record)
      idle(record)
      local md = notes.dir() .. "/20261029-test.claude.md"
      assert.truthy(H.read(md):find("Fixing login", 1, true))
      assert.equals("Fixing login", vim.json.decode(H.read(cn.data_path(md))).summary)
      assert.equals("20261029-test", changed)

      local args = H.read(log .. "/args")
      for _, flag in ipairs { "--safe-mode", "--no-session-persistence", "--json-schema", "haiku" } do
        assert.truthy(args:find(flag, 1, true), flag)
      end
      assert.equals("tab=[]\n", H.read(log .. "/env"))
      local stdin = H.read(log .. "/stdin")
      assert.truthy(stdin:find("token=[redacted]", 1, true))
      assert.is_nil(stdin:find("abc123", 1, true))
      -- No temporary files left beside the sheet.
      for name in vim.fs.dir(notes.dir()) do
        assert.is_nil(name:find "%.tmp$", name)
      end
    end)

    it("writes nothing when notes are switched off while it runs", function()
      H.write(log .. "/delay", "1")
      local record = claude_tab()
      cn.refresh(record)
      H.wait(3000, function()
        return H.exists(log .. "/args")
      end)
      ft.update(record.buf, { notes_on = false })
      idle(record)
      assert.is_false(H.exists(notes.dir() .. "/20261029-test.claude.md"))
    end)

    it("writes nothing to a note the tab moved off while it ran", function()
      H.write(log .. "/delay", "1")
      local record = claude_tab()
      cn.refresh(record)
      H.wait(3000, function()
        return H.exists(log .. "/args")
      end)
      ft.update(record.buf, { note_id = "20261029-other" })
      idle(record)
      assert.is_false(H.exists(notes.dir() .. "/20261029-test.claude.md"))
      assert.is_false(H.exists(notes.dir() .. "/20261029-other.claude.md"))
    end)

    it("runs once more, not once per turn, for turns that end while it runs", function()
      H.write(log .. "/delay", "1")
      local record = claude_tab()
      cn.refresh(record)
      H.wait(3000, function()
        return H.exists(log .. "/args")
      end)
      cn.refresh(record)
      cn.refresh(record)
      cn.refresh(record)
      H.flush(100)
      idle(record)
      assert.equals(2, runs())
    end)

    it("warns once when claude fails and leaves the notes as they were", function()
      local messages = H.capture_notify()
      local md = H.write(notes.dir() .. "/20261029-test.claude.md", "old sheet\n")
      H.write(log .. "/code", "1")
      local record = claude_tab()
      cn.refresh(record)
      idle(record)
      cn.refresh(record)
      idle(record)
      assert.equals("old sheet\n", H.read(md))
      local warnings = vim.tbl_filter(function(m)
        return tostring(m.msg):find("claude failed", 1, true) ~= nil
      end, messages)
      assert.equals(1, #warnings)
      -- A good run after still works.
      H.write(log .. "/code", "0")
      cn.refresh(record)
      idle(record)
      assert.truthy(H.read(md):find("Fixing login", 1, true))
    end)

    it("says so when claude isn't on PATH", function()
      local messages = H.capture_notify()
      local executable = vim.fn.executable
      H.stub(vim.fn, "executable", function(name)
        return name == "claude" and 0 or executable(name)
      end)
      local record = claude_tab()
      cn.refresh(record)
      idle(record)
      assert.is_not_nil(H.notified(messages, "claude isn't on PATH"))
      assert.equals(0, runs())
    end)

    it("leaves a shared note to the first tab that has it", function()
      local messages = H.capture_notify()
      claude_tab()
      local second = claude_tab()
      cn.refresh(second)
      assert.is_not_nil(H.notified(messages, "an earlier tab with these notes"))
      H.flush(200)
      assert.equals(0, runs())
    end)

    it("does nothing with the setting off", function()
      local messages = H.capture_notify()
      settings.set("claude_notes", false)
      cn.refresh(claude_tab())
      assert.is_not_nil(H.notified(messages, "switched off"))
      H.flush(200)
      assert.equals(0, runs())
    end)
  end)
end)
