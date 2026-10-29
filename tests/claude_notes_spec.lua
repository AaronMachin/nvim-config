-- lua/floatterm/claude_notes: drawing the dossier and its plain-text copy, reading
-- older shapes, redacting secrets, reading the turn from a transcript, and the run's
-- guards, with a fake `claude` (never the real one).

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
    -- A session as Claude would describe it, in the current shape.
    local function dossier()
      return {
        title = "SD-494 · Console partner sign-in",
        summary = "Partner sign-in through Cognito",
        now = "Task 1: schema, model and factory",
        hashtags = { "identity", "cognito", "signin", "runbook" },
        tasks = {
          task("Design spec approved", "done"),
          task("Task 1: schema, model and factory", "in_progress", "Sonnet implementing"),
          task("Tasks 2–13", "pending"),
          task("Confirm COGNITO_ACCOUNTS spelling", "blocked", "not settled"),
        },
        links = {
          {
            title = "SD-494 · this session's ticket",
            url = "https://x.atlassian.net/browse/SD-494",
            note = "In development",
          },
          { title = "SD-540 · console sign-in", url = "https://x.atlassian.net/browse/SD-540", note = "Created" },
          { title = "PR #231 cloud/console", url = "https://github.com/cloud/console/pull/231", note = "Opened" },
          { title = "PR #228 cloud/idp-api", url = "https://github.com/cloud/idp-api/pull/228", note = "Reviewing" },
        },
        decisions = { "one", "two", "three", "four", "five", "six" },
        details = { "a", "b", "c", "d", "e" },
      }
    end

    -- The display column `word` starts at in `line`.
    local function col(line, word)
      local at = line:find(word, 1, true)
      return at and vim.fn.strdisplaywidth(line:sub(1, at - 1)) or nil
    end

    it("draws the dossier at 80 columns", function()
      local lines = cn.render(dossier(), { width = 80, status = "working" })
      assert.same({
        " ✳ SD-494 · Console partner sign-in",
        " ◌ working · Task 1: schema, model and factory               ▕████▊░░░░░░░░▏ 37%",
        " #identity #cognito #signin #runbook",
        "",
        " LINKS",
        "  SD-494 · this session's ticket  In development",
        "  SD-540 · console sign-in        Created",
        "  PR #231 cloud/console           Opened",
        "  PR #228 cloud/idp-api           Reviewing",
        "",
        " PLAN",
        "  ✓ Design spec approved",
        "  ▸ Task 1: schema, model and factory  Sonnet implementing",
        "  · Tasks 2–13",
        "  ! Confirm COGNITO_ACCOUNTS spelling  blocked: not settled",
        "",
        " ▸ Decisions (6) d   ▸ Details (5) t",
      }, lines)
    end)

    for _, width in ipairs { 40, 80, 120 } do
      it("fits " .. width .. " columns, with the bar at the right end and the columns lined up", function()
        local lines = cn.render(dossier(), { width = width, status = "working" })
        for _, line in ipairs(lines) do
          assert.is_true(vim.fn.strdisplaywidth(line) <= width, line)
          assert.is_nil(line:find "%s$", "trailing space: " .. line)
        end
        assert.equals(" ✳ SD-494 · Console partner sign-in", lines[1])
        assert.truthy(lines[2]:find "^ ◌ working · ")
        assert.truthy(lines[2]:find "▏ 37%%$")
        assert.equals(width, vim.fn.strdisplaywidth(lines[2]))
        assert.equals(" #identity #cognito #signin #runbook", lines[3])

        -- Every note starts in one column, and so does every detail.
        local notes_at = {}
        for _, note in ipairs { "In development", "Created", "Opened", "Reviewing" } do
          local _, line = find_line(lines, note, 1, true)
          table.insert(notes_at, col(line, note))
        end
        assert.equals(1, #vim.fn.uniq(vim.fn.sort(notes_at)), vim.inspect(notes_at))
        local _, doing = find_line(lines, "^  ▸ ")
        local _, blocked = find_line(lines, "^  ! ")
        assert.equals(col(blocked, "blocked:"), col(doing, "Sonnet"))
        assert.is_not_nil(find_line(lines, "^ ▸ Decisions %(6%) d   ▸ Details %(5%) t$"))
      end)
    end

    it("cuts names and notes with … to fit a narrow pane", function()
      local lines = cn.render(dossier(), { width = 40, status = "working" })
      local _, doing = find_line(lines, "^  ▸ ")
      assert.equals("  ▸ Task 1: schema, mo…  Sonnet impleme…", doing)
      local _, ticket = find_line(lines, "^  SD%-494")
      assert.equals("  SD-494 · this session…  In development", ticket)
    end)

    it("uses no emoji, only symbols one cell wide", function()
      local data = dossier()
      for i = 1, 5 do
        table.insert(data.tasks, task("more " .. i, "done"))
      end
      local lines = cn.render(data, { width = 80, status = "needs_you", needs_you = "Allow Bash?" })
      vim.list_extend(lines, (cn.render(dossier(), { width = 80, status = "done", open = { decisions = true } })))
      for _, line in ipairs(lines) do
        -- One cell per character: an emoji is two, and won't line up.
        assert.equals(vim.fn.strchars(line), vim.fn.strdisplaywidth(line), line)
        for _, code in ipairs(vim.fn.str2list(line)) do
          assert.is_false(code >= 0x1F000 or (code >= 0x2600 and code <= 0x26FF), line)
        end
      end
    end)

    it("shows link titles as links and keeps the URL out of the text", function()
      local lines, highlights, targets = cn.render(dossier(), { width = 80 })
      for _, line in ipairs(lines) do
        assert.is_nil(line:find("https://", 1, true), line)
      end
      local links = vim.tbl_filter(function(t)
        return t.kind == "link"
      end, targets)
      assert.equals(4, #links)
      assert.equals("https://github.com/cloud/console/pull/231", links[3].url)
      assert.equals("PR #231 cloud/console", lines[links[3].line + 1]:sub(links[3].col + 1, links[3].end_col))
      local styled = vim.tbl_filter(function(hl)
        return hl.line == links[3].line and hl.group == "FloatTermNotesLink"
      end, highlights)
      assert.equals(1, #styled)
      assert.equals(links[3].col, styled[1].col)
    end)

    it("folds decisions and details by default, and shows the open ones under the toggles", function()
      local lines, _, targets = cn.render(dossier(), { width = 80 })
      assert.is_nil(find_line(lines, "three"))
      local folds = vim.tbl_filter(function(t)
        return t.kind == "fold"
      end, targets)
      assert.same({ "decisions", "details" }, { folds[1].name, folds[2].name })
      assert.equals(folds[1].line, folds[2].line)
      assert.equals("▸ Details (5) t", lines[folds[2].line + 1]:sub(folds[2].col + 1, folds[2].end_col))

      lines = cn.render(dossier(), { width = 80, open = { details = true } })
      local toggles = find_line(lines, "Details %(5%)")
      assert.equals(" ▸ Decisions (6) d   ▾ Details (5) t", lines[toggles])
      assert.same({ "", " DETAILS", "  - a", "  - b" }, vim.list_slice(lines, toggles + 1, toggles + 4))
      assert.is_nil(find_line(lines, "three"))
    end)

    it("wraps long decisions under their dash, and puts the toggles on a line each when narrow", function()
      local data = dossier()
      data.decisions = { "Use one Cognito pool per region rather than one per partner" }
      local lines = cn.render(data, { width = 30, open = { decisions = true } })
      assert.is_not_nil(find_line(lines, "^ ▾ Decisions %(1%) d$"))
      assert.is_not_nil(find_line(lines, "^ ▸ Details %(5%) t$"))
      local i = find_line(lines, "^  %- Use one")
      assert.truthy(lines[i + 1]:find "^    %S")
      for _, line in ipairs(lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 30, line)
      end
    end)

    it("leaves out sections with nothing in them", function()
      local lines = cn.render { title = "t", tasks = {}, links = {}, decisions = {}, details = {} }
      assert.same({ " ✳ t" }, lines)
    end)

    it("works the percentage out from the tasks, half for one under way, rounded down", function()
      local lines = cn.render { tasks = { task("a", "done"), task("b", "in_progress") } }
      assert.is_not_nil(find_line(lines, " 75%%$"))
      lines = cn.render { tasks = { task("a", "done"), task("b", "pending"), task("c", "blocked") } }
      assert.is_not_nil(find_line(lines, " 33%%$"))
    end)

    it("colours the bar green, blue while one is under way, red if one is blocked", function()
      local function colour(tasks)
        local lines, highlights = cn.render { now = "x", tasks = tasks }
        local row = find_line(lines, "▏ %d+%%$") - 1
        for _, hl in ipairs(highlights) do
          if hl.line == row and hl.group:match "^Diagnostic" then
            return hl.group
          end
        end
      end
      assert.equals("DiagnosticOk", colour { task("a", "done") })
      assert.equals("DiagnosticInfo", colour { task("a", "done"), task("b", "in_progress") })
      assert.equals("DiagnosticError", colour { task("a", "in_progress"), task("b", "blocked") })
    end)

    it("shows what Claude is asking in place of what it's doing, and tidies hashtags", function()
      local lines, highlights = cn.render({
        title = "t",
        now = "writing",
        hashtags = { "#auth", "two words" },
        tasks = { task("a", "pending") },
      }, { width = 60, status = "needs_you", needs_you = "Allow   Bash?" })
      assert.truthy(lines[2]:find "^ ● Allow Bash%? +▕")
      assert.is_nil(lines[2]:find("writing", 1, true))
      assert.equals(" #auth #two-words", lines[3])
      local asking = vim.tbl_filter(function(hl)
        return hl.line == 1 and hl.group == "FloatTermNeedsYou"
      end, highlights)
      assert.equals(1, #asking)
      lines = cn.render({ title = "t", now = "writing" }, { status = "needs_you", needs_you = "" })
      assert.equals(" ● needs you", lines[2])
    end)

    it("folds done tasks into one row past six, and shows at most six task rows", function()
      local tasks = { task("d1", "done"), task("d2", "done") }
      for i = 1, 10 do
        table.insert(tasks, task("task " .. i, i == 1 and "in_progress" or "pending", i == 1 and "writing" or nil))
      end
      local lines = cn.render { tasks = tasks }
      local plan = find_line(lines, "^ PLAN$")
      local rows = vim.list_slice(lines, plan + 1, plan + 6)
      assert.equals("  ✓ 2 done", rows[1])
      assert.truthy(rows[2]:find "^  ▸ task 1 +writing$", rows[2])
      assert.equals("  · 6 more", rows[6])
      assert.is_nil(lines[plan + 7])
      assert.is_nil(find_line(lines, "d1"))
    end)

    it("keeps names, notes and items on one line each", function()
      local lines = cn.render {
        title = "a\nb",
        tasks = { task("fix\nlogin", "in_progress", "reading\nlogs") },
        links = { { url = "https://github.com/o/r/pull/1", title = "the\nfix", note = "Opened\nnow" } },
        details = { "one\ntwo" },
      }
      for _, line in ipairs(lines) do
        assert.is_nil(line:find("\n", 1, true), line)
      end
      assert.is_not_nil(find_line(lines, "fix login +reading logs"))
      assert.is_not_nil(find_line(lines, "the fix +Opened now"))
    end)

    it("reads older shapes: PRs and links without notes, no title, now or decisions", function()
      local old = {
        summary = "Fixing login\nsecond line",
        hashtags = { "auth" },
        tasks = { task("fix", "in_progress", "reading logs") },
        prs = { { url = "https://github.com/o/r/pull/1", title = "the fix" }, { url = "PR 2", title = "no link" } },
        links = { { url = "https://jira.example.com/browse/SD-1", title = "ticket" }, { url = "SD-2", title = "x" } },
        details = { "- branch SD-1-login" },
      }
      local data = cn.normalise(old)
      assert.equals("Fixing login", data.title)
      assert.equals("fix", data.now)
      assert.same({}, data.decisions)
      assert.same({ "https://github.com/o/r/pull/1", "https://jira.example.com/browse/SD-1" }, {
        data.links[1].url,
        data.links[2].url,
      })
      local lines = cn.render(old, { width = 60, status = "working" })
      assert.equals(" ✳ Fixing login", lines[1])
      assert.truthy(lines[2]:find "^ ◌ working · fix ")
      assert.is_not_nil(find_line(lines, "^  the fix$"))
      assert.is_not_nil(find_line(lines, "^  ticket$"))
      assert.is_not_nil(find_line(lines, "^ ▸ Details %(1%) t$"))
      assert.is_nil(find_line(lines, "no link"))
      assert.is_nil(find_line(lines, "Decisions"))
    end)
  end)

  describe("the plain-text copy", function()
    it("writes the same content with the URLs out, for Claude in the tab", function()
      local text = cn.text {
        title = "SD-494 · Console partner sign-in",
        summary = "Partner sign-in",
        now = "Task 1",
        hashtags = { "identity" },
        tasks = {
          task("Design", "done"),
          task("Task 1", "in_progress", "Sonnet implementing"),
          task("Rest", "pending"),
        },
        links = {
          { title = "PR #231 cloud/console", url = "https://github.com/cloud/console/pull/231", note = "Opened" },
          { title = "Runbook", url = "https://wiki.example.com/runbook", note = "" },
        },
        decisions = { "One pool per region" },
        details = { "Branch SD-494-signin" },
      }
      assert.equals(
        table.concat({
          "SD-494 · Console partner sign-in",
          "Partner sign-in",
          "Now: Task 1",
          "#identity",
          "",
          "Links",
          "- PR #231 cloud/console (Opened): https://github.com/cloud/console/pull/231",
          "- Runbook: https://wiki.example.com/runbook",
          "",
          "Plan (50% done)",
          "- [done] Design",
          "- [in progress] Task 1: Sonnet implementing",
          "- [pending] Rest",
          "",
          "Decisions",
          "- One pool per region",
          "",
          "Details",
          "- Branch SD-494-signin",
        }, "\n"),
        text
      )
    end)

    it("writes an older shape's PRs and links too", function()
      local text = cn.text { summary = "s", prs = { { url = "https://github.com/o/r/pull/1", title = "fix" } } }
      assert.truthy(text:find("- fix: https://github.com/o/r/pull/1", 1, true))
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
      { "https://s3/f?X-Amz-Signature=abc123&a=1", "https://s3/f?X-Amz-Signature=[redacted]&a=1" },
      { "see https://x/cb#access_token=abc&state=1", "see https://x/cb#access_token=[redacted]&state=1" },
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

    it("keeps links whole", function()
      for _, url in ipairs {
        "https://docs.google.com/document/d/1aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dF3hJ5kL7nQ2/edit",
        "https://drive.google.com/file/d/1A2b3C4d5E6f7G8h9I0jKlMnOpQrStUvWxYz12345/view?usp=sharing",
        "https://www.figma.com/design/AbC123xYz456QwErTy7890aBcDeFgHiJkLmNoP/Login?node-id=1-2&t=AbCdEfGh12345678-1",
        "https://www.loom.com/share/0a1b2c3d4e5f60718293a4b5c6d7e8f9?sid=Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0EdCbA98765",
        "https://github.com/o/r/pull/12#discussion_r1234567",
        "https://github.com/o/r/blob/main/app/Auth/TokenController.php",
      } do
        assert.equals("open " .. url .. " now", cn.redact("open " .. url .. " now"))
      end
    end)

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
            title = "SD-1 · Login",
            summary = "Fixing login",
            now = "Writing the fix",
            hashtags = { "auth" },
            tasks = { { name = "fix", state = "done" } },
            links = { { title = "PR #1 o/r", url = "https://github.com/o/r/pull/1", note = "Opened" } },
            decisions = {},
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
      -- The .md is plain text with the URLs written out.
      assert.truthy(H.read(md):find "^SD%-1 · Login\nFixing login\nNow: Writing the fix\n")
      assert.truthy(H.read(md):find "\n%- PR #1 o/r %(Opened%): https://github%.com/o/r/pull/1\n")
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
