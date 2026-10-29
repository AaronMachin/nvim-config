-- lua/floatterm/overview: every Claude tab, by state, with its notes.

local H = require "test_helpers"

local ft, notes, overview

describe("Claude overview", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    notes = require "floatterm.notes"
    overview = require "floatterm.overview"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  local function claude_tab(label, fields, cwd)
    local buf = H.sleep_tab { kind = "claude", label = label, cwd = cwd }
    ft.update(buf, fields or {})
    return buf
  end

  it("lists Claude tabs only: needs you, then working, then done, then by name", function()
    H.sleep_tab { label = "shell" }
    claude_tab("zeta", { status = "working" })
    claude_tab("beta", { status = "done" })
    claude_tab("alpha", { status = "done" })
    claude_tab("gamma", { status = "needs_you" })
    claude_tab "new"
    local names = vim.tbl_map(function(item)
      return item.name
    end, overview.list())
    assert.same({ "gamma", "zeta", "alpha", "beta", "new" }, names)
  end)

  it("names the worktree a tab is in, and its notes' title and what Claude is doing", function()
    local repo = H.repo()
    local sub = repo.main .. "/app/Http"
    vim.fn.mkdir(sub, "p")
    local buf = claude_tab("api", { note_id = "20261029-ov01" }, sub)
    local json = notes.dir() .. "/20261029-ov01.claude.json"
    H.write(json, vim.json.encode { title = "SD-494 · Sign-in", now = "Task 1", summary = "Fixing login" })
    local item = overview.list()[1]
    assert.equals("app", item.folder)
    assert.equals("SD-494 · Sign-in · Task 1", item.summary)
    assert.equals(buf, item.record.buf)
    -- Older notes, without either: the summary's first line.
    H.write(json, vim.json.encode { summary = "Fixing login\nsecond line" })
    assert.equals("Fixing login", overview.list()[1].summary)
  end)

  it("previews the dossier at its width, with what Claude is asking in the header", function()
    claude_tab("api", { status = "needs_you", needs_you_message = "Allow Bash?", note_id = "20261029-ov02" })
    H.write(
      notes.dir() .. "/20261029-ov02.claude.json",
      vim.json.encode {
        title = "SD-1 · Deploying",
        now = "deploying",
        tasks = { { name = "deploy", state = "in_progress" } },
        links = { { title = "PR #7 o/r", url = "https://github.com/o/r/pull/7", note = "Opened" } },
      }
    )
    local lines, highlights = overview.preview_lines(overview.list()[1], 50)
    assert.equals(" ✳ SD-1 · Deploying", lines[1])
    assert.truthy(lines[2]:find "^ ● Allow Bash%? +▕")
    assert.equals(50, vim.fn.strdisplaywidth(lines[2]))
    assert.truthy(vim.tbl_contains(lines, "  PR #7 o/r  Opened"))
    local groups = {}
    for _, hl in ipairs(highlights) do
      if hl.line == 1 then
        groups[hl.group] = true
      end
    end
    assert.is_true(groups.FloatTermNeedsYou)
    assert.is_true(groups.DiagnosticInfo)
  end)

  it("previews an old-format sheet with what Claude is asking on top", function()
    claude_tab("api", { status = "needs_you", needs_you_message = "Allow Bash?", note_id = "20261029-ov03" })
    H.write(notes.dir() .. "/20261029-ov03.claude.md", "# Summary of chat\nDeploying\n")
    local lines, highlights = overview.preview_lines(overview.list()[1], 50)
    assert.same({ "● needs you · Allow Bash?", "", "# Summary of chat", "Deploying" }, lines)
    assert.equals("FloatTermNeedsYou", highlights[1].group)
  end)

  it("says when a tab has no notes yet", function()
    claude_tab "api"
    local lines = overview.preview_lines(overview.list()[1], 50)
    assert.same({ "No Claude notes for this tab yet" }, lines)
  end)

  it("Ctrl+o opens the first link that looks like a PR, else the first link", function()
    local ticket = { title = "SD-1 · this session's ticket", url = "https://jira.example.com/browse/SD-1", note = "" }
    -- By its URL, without trailing punctuation.
    assert.equals(
      "https://github.com/o/r/pull/7",
      overview.first_pr { data = { links = { ticket, { title = "the fix", url = "https://github.com/o/r/pull/7)." } } } }
    )
    -- By its title.
    assert.equals(
      "https://gitlab.example.com/o/r/-/merge_requests/3",
      overview.first_pr {
        data = {
          links = { ticket, { title = "PR !3 o/r", url = "https://gitlab.example.com/o/r/-/merge_requests/3" } },
        },
      }
    )
    assert.equals("https://jira.example.com/browse/SD-1", overview.first_pr { data = { links = { ticket } } })
    assert.is_nil(overview.first_pr { data = { summary = "s" } })
    -- Older data's PRs.
    assert.equals(
      "https://github.com/o/r/pull/9",
      overview.first_pr { data = { prs = { { url = "https://github.com/o/r/pull/9", title = "fix" } } } }
    )
  end)

  it("Ctrl+o reads the .md's links where there's no data", function()
    local from_md = overview.first_pr {
      lines = {
        "# PRs",
        "- Fix (see https://jira.example.com/browse/SD-1): https://github.com/o/r/pull/5.",
      },
    }
    assert.equals("https://github.com/o/r/pull/5", from_md)
    local other = overview.first_pr { lines = { "# PRs", "- MR: https://gitlab.example.com/o/r/-/merge_requests/3," } }
    assert.equals("https://gitlab.example.com/o/r/-/merge_requests/3", other)
    local plain = overview.first_pr {
      lines = {
        "SD-1 · Login",
        "See https://example.com/elsewhere",
        "",
        "Links",
        "- SD-1 · ticket (In development): https://jira.example.com/browse/SD-1",
        "- PR #4 o/r (Opened): https://github.com/o/r/pull/4",
        "",
        "Details",
        "- docs https://github.com/o/r/pull/99",
      },
    }
    assert.equals("https://github.com/o/r/pull/4", plain)
  end)

  it("says so when there are no Claude tabs", function()
    local messages = H.capture_notify()
    H.sleep_tab()
    overview.pick()
    assert.is_not_nil(H.notified(messages, "No Claude tabs open"))
  end)
end)
