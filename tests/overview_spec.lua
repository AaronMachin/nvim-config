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

  it("names the worktree a tab is in, and its notes' summary", function()
    local repo = H.repo()
    local sub = repo.main .. "/app/Http"
    vim.fn.mkdir(sub, "p")
    local buf = claude_tab("api", { note_id = "20261029-ov01" }, sub)
    H.write(notes.dir() .. "/20261029-ov01.claude.json", vim.json.encode { summary = "Fixing login\nsecond line" })
    local item = overview.list()[1]
    assert.equals("app", item.folder)
    assert.equals("Fixing login", item.summary)
    assert.equals(buf, item.record.buf)
  end)

  it("previews what Claude is asking on top, then its notes", function()
    claude_tab("api", { status = "needs_you", needs_you_message = "Allow Bash?", note_id = "20261029-ov02" })
    H.write(
      notes.dir() .. "/20261029-ov02.claude.json",
      vim.json.encode {
        summary = "Deploying",
        tasks = { { name = "deploy", state = "in_progress" } },
      }
    )
    local lines, highlights = overview.preview_lines(overview.list()[1], 50)
    assert.equals("● Needs you: Allow Bash?", lines[1])
    assert.equals("FloatTermNeedsYou", highlights[1].group)
    assert.truthy(vim.tbl_contains(lines, "Deploying"))
    -- Highlights below are moved down past the question.
    local bar_line
    for i, line in ipairs(lines) do
      if line:find "^%[" then
        bar_line = i - 1
      end
    end
    local found = false
    for _, hl in ipairs(highlights) do
      found = found or (hl.line == bar_line and hl.group == "DiagnosticInfo")
    end
    assert.is_true(found)
  end)

  it("says when a tab has no notes yet", function()
    claude_tab "api"
    local lines = overview.preview_lines(overview.list()[1], 50)
    assert.same({ "No Claude notes for this tab yet" }, lines)
  end)

  it("Ctrl+o prefers a GitHub PR link, without trailing punctuation", function()
    local from_data = overview.first_pr {
      data = {
        prs = {
          { url = "https://jira.example.com/browse/SD-1" },
          { url = "https://github.com/o/r/pull/7)." },
        },
      },
    }
    assert.equals("https://github.com/o/r/pull/7", from_data)
    local from_md = overview.first_pr {
      lines = {
        "# PRs",
        "- Fix (see https://jira.example.com/browse/SD-1): https://github.com/o/r/pull/5.",
      },
    }
    assert.equals("https://github.com/o/r/pull/5", from_md)
    local other = overview.first_pr { lines = { "# PRs", "- MR: https://gitlab.example.com/o/r/-/merge_requests/3," } }
    assert.equals("https://gitlab.example.com/o/r/-/merge_requests/3", other)
  end)

  it("says so when there are no Claude tabs", function()
    local messages = H.capture_notify()
    H.sleep_tab()
    overview.pick()
    assert.is_not_nil(H.notified(messages, "No Claude tabs open"))
  end)
end)
