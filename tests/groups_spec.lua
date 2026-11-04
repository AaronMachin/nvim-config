-- lua/floatterm/groups: tabs under a parent tab. Linking by hand (g in the tab bar) and
-- refusing loops, the tree in both bar layouts and folding, tab order, the suggestion
-- from a first prompt into .superpowers/<slug>/ (an owner from a transcript, else a new
-- group heading), WORKSTREAMS and "part of" in the large view, and saving and
-- restoring the links (a child nvim, as restore runs once per nvim).

local H = require "test_helpers"
local api = vim.api

local ft, groups, tabbar, settings, notes, claude

local function keys(text)
  api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "x", false)
end

local function find_line(lines, text)
  for i, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return i, line
    end
  end
end

local function names()
  return vim.tbl_map(function(record)
    return ft.name(record)
  end, ft.tabs())
end

local function draw()
  tabbar.redraw()
  return tabbar.lines()
end

describe("tab groups", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    groups = require "floatterm.groups"
    tabbar = require "floatterm.tabbar"
    settings = require "floatterm.settings"
    notes = require "floatterm.notes"
    claude = require "floatterm.claude"
    notes.setup()
    H.isolate()
  end)

  after_each(function()
    pcall(vim.cmd, "stopinsert")
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  it("gives every tab a uid of its own", function()
    local a, b = H.sleep_tab(), H.sleep_tab()
    assert.truthy(ft.record(a).uid:match "^%x+$")
    assert.is_not.equals(ft.record(a).uid, ft.record(b).uid)
  end)

  describe("linking", function()
    it("g in the tab bar numbers the tabs it can go under and asks for one, 0 unlinks", function()
      local lead = H.sleep_tab { label = "lead" }
      H.sleep_tab { label = "other" }
      local child = H.sleep_tab { label = "child" }
      tabbar.enter()
      local shown
      H.stub(vim.ui, "input", function(opts, on_confirm)
        shown = { prompt = opts.prompt, lines = tabbar.lines() }
        on_confirm "1"
      end)
      keys "g"
      -- The bar numbered the other tabs, not this one.
      assert.truthy(find_line(shown.lines, "1 $ lead"), table.concat(shown.lines, "\n"))
      assert.truthy(find_line(shown.lines, "2 $ other"))
      assert.is_nil(find_line(shown.lines, "3 "))
      assert.equals("Put child under tab number (0 for none): ", shown.prompt)
      assert.equals(ft.record(lead).uid, ft.record(child).parent_uid)
      -- The numbers go once it's answered.
      assert.is_nil(find_line(draw(), "1 $ lead"))
      -- Right after its parent now.
      assert.same({ "lead", "child", "other" }, names())
      H.answer_input "0"
      tabbar.enter()
      keys "g"
      assert.is_nil(ft.record(child).parent_uid)
    end)

    it("along the top too, and a number no tab has changes nothing", function()
      settings.set("tabbar", "top")
      H.sleep_tab { label = "lead" }
      local child = H.sleep_tab { label = "child" }
      local line
      H.stub(vim.ui, "input", function(_, on_confirm)
        line = tabbar.lines()[1]
        on_confirm "7"
      end)
      local messages = H.capture_notify()
      groups.pick_parent(child)
      assert.truthy(line:find("1 $ lead", 1, true), line)
      assert.is_nil(ft.record(child).parent_uid)
      assert.is_not_nil(H.notified(messages, "no tab numbered 7"))
    end)

    it("falls back to a list when the tab bar is off", function()
      settings.set("tabbar", "off")
      local lead = H.sleep_tab { label = "lead" }
      local child = H.sleep_tab { label = "child" }
      local prompts = H.answer_select "lead"
      groups.pick_parent(child)
      assert.equals("Put child under", prompts[1])
      assert.equals(ft.record(lead).uid, ft.record(child).parent_uid)
    end)

    it("refuses a tab under itself or under one of its own children", function()
      local lead = H.sleep_tab { label = "lead" }
      local child = H.sleep_tab { label = "child" }
      local grandchild = H.sleep_tab { label = "grandchild" }
      assert.is_true(groups.set_parent(child, lead))
      assert.is_true(groups.set_parent(grandchild, child))
      local messages = H.capture_notify()
      assert.is_false(groups.set_parent(lead, grandchild))
      assert.is_false(groups.set_parent(lead, lead))
      assert.is_nil(ft.record(lead).parent_uid)
      assert.is_not_nil(H.notified(messages, "it's under it"))
      -- The picker doesn't number them either.
      local lines
      H.stub(vim.ui, "input", function(_, on_confirm)
        lines = tabbar.lines()
        on_confirm(nil)
      end)
      groups.pick_parent(lead)
      assert.is_nil(find_line(lines, "1 "), table.concat(lines, "\n"))
    end)
  end)

  describe("in the tab bar", function()
    local lead, a, b

    before_each(function()
      lead = H.sleep_tab { label = "lead" }
      a = H.sleep_tab { label = "a" }
      b = H.sleep_tab { label = "b" }
      H.sleep_tab { label = "solo" }
      groups.set_parent(a, lead)
      groups.set_parent(b, lead)
      ft.focus_buf(b)
    end)

    it("draws children under their parent down the left, with the tree", function()
      local lines = draw()
      local at = find_line(lines, "$ lead")
      assert.equals("  $ lead", lines[at])
      assert.truthy(lines[at + 1]:find "^  %S") -- its command, not part of the tree
      assert.equals("  ├ $ a", lines[at + 2])
      assert.truthy(lines[at + 3]:find "^  │ ")
      assert.equals("▶ └ $ b", lines[at + 4])
      assert.truthy(lines[at + 5]:find "^    %S")
      -- A blank line between trees, not inside one.
      assert.equals("", lines[at + 6])
      assert.equals("  $ solo", lines[at + 7])
    end)

    it("puts children right after their parent along the top, marked", function()
      settings.set("tabbar", "top")
      local line = draw()[1]
      local lead_at = line:find("$ lead", 1, true)
      local a_at = line:find("│ └ $ a", 1, true)
      local b_at = line:find("│ ▶ └ $ b", 1, true)
      local solo_at = line:find("│ $ solo", 1, true)
      assert.truthy(lead_at and a_at and b_at and solo_at, line)
      assert.is_true(lead_at < a_at and a_at < b_at and b_at < solo_at)
    end)

    it("za folds a parent's children away and back, from the parent or a child", function()
      draw()
      tabbar.enter()
      -- On b (a child): folds its parent, and the selection moves to it.
      keys "za"
      assert.is_true(ft.record(lead).children_folded)
      local lines = draw()
      assert.is_nil(find_line(lines, "$ a"))
      assert.is_nil(find_line(lines, "$ b"))
      -- The current tab (b) is folded away, so its parent's row is marked.
      local _, line = find_line(lines, "$ lead")
      assert.truthy(line:find "^▶ %$ lead ▸2", line)
      settings.set("tabbar", "top")
      assert.truthy(draw()[1]:find("$ lead ▸2", 1, true))
      settings.set("tabbar", "left")
      tabbar.enter()
      keys "za"
      assert.is_nil(ft.record(lead).children_folded)
      assert.is_not_nil(find_line(draw(), "$ a"))
    end)

    it("next and previous step over folded children", function()
      groups.toggle_fold(lead)
      ft.focus_buf(lead)
      ft.next_tab()
      assert.equals("solo", ft.name(ft.record(ft.current_buf())))
      ft.previous_tab()
      assert.equals("lead", ft.name(ft.record(ft.current_buf())))
    end)

    it("moves a parent with its children, and a child among its siblings", function()
      local solo = ft.tabs()[4].buf
      ft.move_tab(solo, -1)
      assert.same({ "solo", "lead", "a", "b" }, names())
      ft.move_tab(lead, 1)
      assert.same({ "solo", "lead", "a", "b" }, names())
      ft.move_tab(b, -1)
      assert.same({ "solo", "lead", "b", "a" }, names())
      ft.move_tab(b, -1)
      assert.same({ "solo", "lead", "b", "a" }, names())
      -- The capitals in the bar too, the selection following the tab.
      ft.focus_buf(solo)
      tabbar.enter()
      keys "J"
      assert.same({ "lead", "b", "a", "solo" }, names())
    end)

    it("lets a child go when its parent closes", function()
      vim.fn.jobstop(ft.record(lead).job)
      H.wait(3000, function()
        return ft.record(lead) == nil
      end)
      H.flush(50)
      assert.is_nil(ft.record(a).parent_uid)
    end)
  end)

  describe("group headings", function()
    it("shows as a heading, focuses its first child, is skipped by next and goes when empty", function()
      local x = H.sleep_tab { label = "x" }
      local y = H.sleep_tab { label = "y" }
      local heading = ft.new_group { label = "epic", before = x }
      groups.set_parent(x, heading)
      groups.set_parent(y, heading)
      assert.same({ "epic", "x", "y" }, names())
      local lines = draw()
      assert.equals("  ▾ epic", lines[1])
      assert.equals("  ├ $ x", lines[2])
      assert.is_true(ft.focus_buf(heading))
      assert.equals(x, ft.current_buf())
      ft.previous_tab()
      assert.equals(y, ft.current_buf())
      ft.next_tab()
      assert.equals(x, ft.current_buf())
      for _, buf in ipairs { x, y } do
        vim.fn.jobstop(ft.record(buf).job)
      end
      H.wait(3000, function()
        return #ft.tabs() == 0
      end, "the empty group heading should go")
    end)
  end)

  describe("suggesting a parent", function()
    local function transcript(writes)
      local entries = {}
      for _, path in ipairs(writes) do
        table.insert(
          entries,
          vim.json.encode {
            type = "assistant",
            message = {
              content = {
                { type = "text", text = "Writing the plan" },
                { type = "tool_use", id = "t1", name = "Write", input = { file_path = path, content = "x" } },
              },
            },
          }
        )
      end
      table.insert(entries, vim.json.encode { type = "user", message = { content = "hello" } })
      return H.write(H.tmpdir "transcripts" .. "/s.jsonl", table.concat(entries, "\n") .. "\n")
    end

    local function claude_tab(label, fields)
      local buf = H.sleep_tab { label = label, kind = "claude" }
      ft.update(buf, fields or {})
      return buf
    end

    local function prompt(buf, text)
      claude.apply(ft.record(buf), { hook_event_name = "UserPromptSubmit", prompt = text })
    end

    it("finds the tab whose Claude wrote into the folder, asks once, and links on Yes", function()
      claude_tab("other", { transcript_path = transcript { "/repo/.superpowers/billing/plan.md" } })
      local owner = claude_tab("planner", {
        transcript_path = transcript { "/repo/README.md", "/repo/.superpowers/auth-flow/plan.md" },
      })
      local worker = claude_tab "worker"
      local prompts = H.answer_select "Yes"
      prompt(worker, "Do task 2 of /repo/.superpowers/auth-flow/plan.md please")
      H.wait(3000, function()
        return ft.record(worker).parent_uid ~= nil
      end)
      assert.equals(ft.record(owner).uid, ft.record(worker).parent_uid)
      assert.same({ "This looks like part of planner (auth-flow). Make it a child?" }, prompts)
      -- The transcript was read once and is kept.
      assert.is_true(groups.scanned[ft.record(owner).transcript_path].slugs["auth-flow"])
    end)

    it("remembers No, and only asks on the first prompt", function()
      claude_tab("planner", { transcript_path = transcript { ".superpowers/auth-flow/spec.md" } })
      local worker = claude_tab "worker"
      local prompts = H.answer_select "No"
      prompt(worker, "Read .superpowers/auth-flow/spec.md")
      H.wait(3000, function()
        return #prompts == 1
      end)
      assert.is_nil(ft.record(worker).parent_uid)
      assert.is_true(ft.record(worker).workstream_asked)
      -- Asked again by hand, or by a later prompt: nothing.
      groups.on_prompt(ft.record(worker), "Read .superpowers/auth-flow/spec.md")
      prompt(worker, "and .superpowers/auth-flow/plan.md")
      H.flush(200)
      assert.equals(1, #prompts)
    end)

    it("asks nothing when no tab has to do with the folder", function()
      local prompts = H.answer_select "Yes"
      local worker = claude_tab "worker"
      prompt(worker, "Read .superpowers/lonely/spec.md")
      H.flush(200)
      assert.same({}, prompts)
      assert.equals("lonely", ft.record(worker).workstream_slug)
      -- A prompt that only names a file in .superpowers, not a folder, isn't one.
      assert.is_nil(groups.slug_of "see .superpowers/notes.md")
    end)

    it("offers a new group heading with another tab pointed at the same folder", function()
      local first = claude_tab "first"
      local second = claude_tab "second"
      H.sleep_tab { label = "shell" }
      local prompts = H.answer_select "Yes"
      prompt(first, "Start on .superpowers/new-thing/plan.md")
      H.flush(100)
      assert.same({}, prompts)
      prompt(second, "Pick up .superpowers/new-thing/plan.md task 3")
      H.wait(3000, function()
        return ft.record(second).parent_uid ~= nil
      end)
      assert.same({ "Group with first under a new 'new-thing' group?" }, prompts)
      local heading = groups.parent(ft.record(second))
      assert.equals("group", heading.kind)
      assert.equals("new-thing", heading.label)
      assert.equals(heading.uid, ft.record(first).parent_uid)
      assert.same({ "new-thing", "first", "second", "shell" }, names())
    end)
  end)

  describe("in the dossier", function()
    local lead, child, opened

    local function view_lines()
      return api.nvim_buf_get_lines(0, 0, -1, false)
    end

    -- The large view's current target, as text.
    local function current()
      local ns = api.nvim_get_namespaces().floatterm_claude_view
      local marks = api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
      local mark = marks[1]
      return mark and api.nvim_buf_get_lines(0, mark[2], mark[2] + 1, false)[1]:sub(mark[3] + 1, mark[4].end_col)
    end

    local function open_view(buf)
      ft.focus_buf(buf)
      notes.redraw()
      api.nvim_set_current_win(notes.state().mine)
      vim.cmd "stopinsert"
      notes.read_claude()
      return api.nvim_get_current_win()
    end

    before_each(function()
      lead = H.sleep_tab { label = "lead", kind = "claude" }
      child = H.sleep_tab { label = "worker", kind = "claude" }
      for buf, data in pairs {
        [lead] = {
          title = "SD-1 · Epic",
          now = "Waiting on workers",
          links = { { title = "SD-1 · epic", url = "https://x.atlassian.net/browse/SD-1", note = "In development" } },
        },
        [child] = {
          title = "SD-2 · Part",
          now = "Task 2: forms",
          tasks = { { name = "one", state = "done" }, { name = "two", state = "in_progress" } },
        },
      } do
        notes.set(buf, true)
        H.write(notes.paths(ft.record(buf)).claude_json, vim.json.encode(data))
      end
      ft.update(child, { status = "working" })
      groups.set_parent(child, lead)
      opened = {}
      H.stub(vim.ui, "open", function(url)
        table.insert(opened, url)
      end)
    end)

    it("lists the children under WORKSTREAMS, and Tab and Enter go to one", function()
      open_view(lead)
      local lines = view_lines()
      local at = find_line(lines, "Workstreams ─")
      assert.truthy(lines[at + 1]:find "^  overall .* 75%%")
      assert.truthy(lines[at + 2]:find "^  ◌ worker +Task 2: forms +.* 75%%$", lines[at + 2])
      keys "<Tab>"
      assert.equals("SD-1 · epic", current())
      keys "<Tab>"
      assert.equals("worker", current())
      keys "<CR>"
      assert.equals(child, ft.current_buf())
      assert.same({}, opened)
    end)

    it("shows part of: the parent in a child's header, and Enter there goes to it", function()
      open_view(child)
      assert.is_not_nil(find_line(view_lines(), " ↳ part of lead"))
      keys "<Tab>"
      assert.equals("lead", current())
      keys "<CR>"
      assert.equals(lead, ft.current_buf())
    end)
  end)

  describe("saving and restoring", function()
    local function folder_key(folder)
      return (folder:gsub("/", "%%"))
    end

    it("keeps uids, parents and folds, and drops links to tabs that didn't come back", function()
      local dir = H.tmpdir "tabs"
      local project = H.tmpdir "project"
      local set = dir .. "/" .. folder_key(project) .. "/a.json"
      H.write(
        set,
        vim.json.encode {
          folder = project,
          saved_at = 1,
          tabs = {
            { kind = "group", uid = "g1", label = "epic", cwd = project },
            { kind = "shell", uid = "s1", cwd = project, label = "in-group", parent_uid = "g1" },
            { kind = "shell", uid = "p1", cwd = project, label = "lead", children_folded = true },
            { kind = "shell", uid = "c1", cwd = project, label = "child", parent_uid = "p1" },
            { kind = "shell", uid = "c2", cwd = project, label = "orphan", parent_uid = "gone" },
            { kind = "group", uid = "g2", label = "empty", cwd = project },
          },
        }
      )
      local out = H.child(
        project,
        [[
        local r = require "floatterm.restore"
        r.setup()
        r.restore()
        vim.wait(300, function() return false end, 20)
        r.save()
        local tabs = {}
        for _, t in ipairs(require("floatterm").tabs()) do
          table.insert(tabs, { kind = t.kind, label = t.label, uid = t.uid, parent_uid = t.parent_uid or false,
            children_folded = t.children_folded or false })
        end
        io.stdout:write(vim.json.encode(tabs))
      ]],
        { floatterm_tabs_dir = dir, floatterm_restore_headless = true }
      )
      local ok, tabs = pcall(vim.json.decode, out)
      assert(ok, out)
      assert.same({
        { kind = "group", label = "epic", uid = "g1", parent_uid = false, children_folded = false },
        { kind = "shell", label = "in-group", uid = "s1", parent_uid = "g1", children_folded = false },
        { kind = "shell", label = "lead", uid = "p1", parent_uid = false, children_folded = true },
        { kind = "shell", label = "child", uid = "c1", parent_uid = "p1", children_folded = false },
        { kind = "shell", label = "orphan", uid = "c2", parent_uid = false, children_folded = false },
      }, tabs)
      -- And saved again the same way.
      local saved = vim.json.decode(H.read(set)).tabs
      assert.equals("group", saved[1].kind)
      assert.equals("g1", saved[2].parent_uid)
      assert.is_true(saved[3].children_folded)
      assert.equals("c1", saved[4].uid)
      assert.equals(5, #saved)
    end)
  end)
end)
