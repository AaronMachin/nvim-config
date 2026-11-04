-- Parent and child tabs, for Claude sessions that are parts of one piece of work.
--
-- A tab can sit under another (its record's parent_uid is the other's uid; uids are
-- kept across restarts by lua/floatterm/restore). The tabs are kept in tree order: a
-- parent, then its children, then theirs. A parent can fold its children away
-- (children_folded on the parent), which hides them in the tab bar and from
-- next/previous. A group heading (kind = "group", lua/floatterm M.new_group) is a
-- parent with no job of its own; it goes once nothing sits under it.
--
-- Linking is by hand (`g` in the tab bar) or suggested: when a Claude tab's first
-- prompt points into a .superpowers/<slug>/ folder, the tab whose Claude wrote files
-- there (found in its transcript) is offered as its parent, once. Without one, another
-- tab whose first prompt pointed at the same folder is offered as a partner under a new
-- group heading named after the folder.
--
-- The parent's dossier lists its children (WORKSTREAMS) and a child's names its parent
-- (see M.dossier_opts, drawn by lua/floatterm/claude_notes).

local M = {}

local api = vim.api

local function ft()
  return require "floatterm"
end

function M.by_uid(uid)
  if not uid then
    return nil
  end
  for _, record in ipairs(ft().tabs()) do
    if record.uid == uid then
      return record
    end
  end
  return nil
end

function M.parent(record)
  return record and M.by_uid(record.parent_uid) or nil
end

-- The tabs directly under `record`, in tab order.
function M.children(record)
  local out = {}
  for _, other in ipairs(ft().tabs()) do
    if record.uid and other.parent_uid == record.uid and other ~= record then
      table.insert(out, other)
    end
  end
  return out
end

-- Whether `record` sits somewhere under `ancestor`. Bounded, so a cycle in a saved set
-- can't loop forever.
function M.is_under(record, ancestor)
  local seen = 0
  local at = M.parent(record)
  while at and seen < 100 do
    if at == ancestor then
      return true
    end
    at = M.parent(at)
    seen = seen + 1
  end
  return false
end

-- Whether a tab is folded away under a parent.
function M.hidden(record)
  local seen = 0
  local at = M.parent(record)
  while at and seen < 100 do
    if at.children_folded then
      return true
    end
    at = M.parent(at)
    seen = seen + 1
  end
  return false
end

-- Every tab in tree order, and the set of those reached from a root (a tab in a cycle
-- isn't).
local function tree_order()
  local tabs = ft().tabs()
  local order, reached = {}, {}
  local function visit(record)
    if reached[record] then
      return
    end
    reached[record] = true
    table.insert(order, record)
    for _, child in ipairs(M.children(record)) do
      visit(child)
    end
  end
  for _, record in ipairs(tabs) do
    if not M.parent(record) then
      visit(record)
    end
  end
  for _, record in ipairs(tabs) do
    if not reached[record] then
      table.insert(order, record)
    end
  end
  return order, reached
end

-- The rows the tab bar draws, in tab order, without folded-away tabs: { record, index
-- (in tabs), depth, last (no later sibling), rails (per level above it, whether that
-- ancestor has a later sibling), folded (how many tabs it folds away, or nil) }.
function M.rows()
  local tabs = ft().tabs()
  local function has_later_sibling(record, i)
    for j = i + 1, #tabs do
      if M.parent(tabs[j]) == M.parent(record) then
        return true
      end
    end
    return false
  end
  local later = {}
  for i, record in ipairs(tabs) do
    later[record] = has_later_sibling(record, i)
  end
  local rows = {}
  for i, record in ipairs(tabs) do
    if not M.hidden(record) then
      local chain = {}
      local at = M.parent(record)
      while at and #chain < 20 do
        table.insert(chain, 1, at)
        at = M.parent(at)
      end
      local rails = {}
      for level = 2, #chain do
        rails[level - 1] = later[chain[level]]
      end
      local folded = nil
      if record.children_folded then
        local count = 0
        for _, other in ipairs(tabs) do
          if M.is_under(other, record) then
            count = count + 1
          end
        end
        folded = count > 0 and count or nil
      end
      table.insert(rows, {
        record = record,
        index = i,
        depth = #chain,
        last = not later[record],
        rails = rails,
        folded = folded,
      })
    end
  end
  return rows
end

-- The row a tab shows on: its own, or its nearest ancestor's when it's folded away.
function M.row_of(rows, record)
  local seen = 0
  while record and seen < 100 do
    for i, row in ipairs(rows) do
      if row.record == record then
        return i
      end
    end
    record = M.parent(record)
    seen = seen + 1
  end
  return nil
end

local tidying = false

-- Drops links to tabs that have gone (or that loop), removes group headings with
-- nothing under them, and puts the tabs in tree order.
function M.tidy()
  local floatterm = package.loaded["floatterm"]
  if tidying or not floatterm then
    return
  end
  tidying = true
  local ok, err = pcall(function()
    local _, reached = tree_order()
    for _, record in ipairs(vim.list_slice(floatterm.tabs())) do
      if record.parent_uid and (not M.parent(record) or not reached[record]) then
        floatterm.update(record.buf, { parent_uid = vim.NIL })
      end
    end
    for _, record in ipairs(vim.list_slice(floatterm.tabs())) do
      if record.kind == "group" and #M.children(record) == 0 then
        floatterm.remove_tab(record.buf)
      end
    end
    local order = tree_order()
    local tabs = floatterm.tabs()
    for i, record in ipairs(order) do
      if tabs[i] ~= record then
        floatterm.set_order(vim.tbl_map(function(r)
          return r.buf
        end, order))
        break
      end
    end
  end)
  tidying = false
  if not ok then
    error(err)
  end
end

local scheduled = false
local function tidy_soon()
  if scheduled then
    return
  end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    pcall(M.tidy)
  end)
end

-- Puts the tab `buf` under the tab `parent_buf` (nil: under nothing). Refuses a tab
-- under itself or under one of its own children. Returns true when linked.
function M.set_parent(buf, parent_buf)
  local floatterm = ft()
  local record = floatterm.record(buf)
  if not record then
    return false
  end
  local parent = parent_buf and floatterm.record(parent_buf) or nil
  if parent_buf and not parent then
    return false
  end
  if parent and (parent == record or M.is_under(parent, record)) then
    vim.notify(
      "floatterm: "
        .. floatterm.name(parent)
        .. " can't be the parent of "
        .. floatterm.name(record)
        .. ", it's under it",
      vim.log.levels.WARN
    )
    return false
  end
  floatterm.update(buf, { parent_uid = parent and parent.uid or vim.NIL })
  M.tidy()
  return true
end

local function glyph(record)
  if record.kind == "group" then
    return "▾ "
  end
  return record.kind == "claude" and "✳ " or "$ "
end

-- When the tab bar isn't showing: a list of the tabs `buf` can go under, and "none".
local function pick_from_list(buf, record, choices)
  local floatterm = ft()
  local items = { { text = "none" } }
  for _, other in ipairs(choices) do
    table.insert(items, { text = floatterm.name(other), record = other })
  end
  vim.ui.select(items, {
    prompt = "Put " .. floatterm.name(record) .. " under",
    format_item = function(item)
      return item.record and (glyph(item.record) .. item.text) or "none (a tab of its own)"
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.set_parent(buf, choice.record and choice.record.buf or nil)
  end)
end

-- `g` in the tab bar and <leader>tp: numbers the tabs `buf` can go under in the tab
-- bar and asks for one (0 for none). Without the bar, a list instead.
function M.pick_parent(buf)
  local floatterm = ft()
  local record = floatterm.record(buf)
  if not record then
    return
  end
  local choices, numbers = {}, {}
  for _, row in ipairs(M.rows()) do
    local other = row.record
    if other ~= record and not M.is_under(other, record) then
      table.insert(choices, other)
      numbers[other] = #choices
    end
  end
  local tabbar = require "floatterm.tabbar"
  if not tabbar.show_numbers(numbers) then
    tabbar.show_numbers(nil)
    pick_from_list(buf, record, choices)
    return
  end
  vim.cmd "redraw"
  vim.ui.input({ prompt = "Put " .. floatterm.name(record) .. " under tab number (0 for none): " }, function(answer)
    tabbar.show_numbers(nil)
    answer = vim.trim(answer or "")
    if answer == "" then
      return
    end
    local n = tonumber(answer)
    if n == 0 then
      M.set_parent(buf, nil)
      return
    end
    local parent = n and choices[n]
    if not parent then
      vim.notify("floatterm: no tab numbered " .. answer, vim.log.levels.WARN)
      return
    end
    M.set_parent(buf, parent.buf)
  end)
end

-- Folds or unfolds a parent's children. On a child, its parent's. Returns the record
-- folded, or nil.
function M.toggle_fold(buf)
  local floatterm = ft()
  local record = floatterm.record(buf)
  if record and #M.children(record) == 0 then
    record = M.parent(record)
  end
  if not record then
    return nil
  end
  floatterm.update(record.buf, { children_folded = (not record.children_folded) or vim.NIL })
  return record
end

-- Moves a tab one place among its siblings, taking its children with it.
function M.move_tab(buf, delta)
  local floatterm = ft()
  local record = floatterm.record(buf)
  if not record then
    return
  end
  local order = tree_order()
  local parent = M.parent(record)
  local siblings = vim.tbl_filter(function(r)
    return M.parent(r) == parent
  end, order)
  local at
  for i, r in ipairs(siblings) do
    if r == record then
      at = i
    end
  end
  local other = siblings[at + (delta < 0 and -1 or 1)]
  if not other then
    return
  end
  -- Each one's block: itself and everything under it, which tree order keeps together.
  local function block(r)
    local first
    for i, x in ipairs(order) do
      if x == r then
        first = i
      end
    end
    local last = first
    while order[last + 1] and M.is_under(order[last + 1], r) do
      last = last + 1
    end
    return first, last
  end
  local a1, a2 = block(delta < 0 and other or record)
  local b1, b2 = block(delta < 0 and record or other)
  local new = vim.list_slice(order, 1, a1 - 1)
  vim.list_extend(new, order, b1, b2)
  vim.list_extend(new, order, a1, a2)
  vim.list_extend(new, order, b2 + 1, #order)
  floatterm.set_order(vim.tbl_map(function(r)
    return r.buf
  end, new))
end

-- Shows the tab with this uid. False when it's gone.
function M.focus_uid(uid)
  local record = M.by_uid(uid)
  return record ~= nil and ft().focus_buf(record.buf)
end

-- Suggesting a parent ---------------------------------------------------------

-- The folder a prompt points into: <slug> in .superpowers/<slug>/, or nil.
function M.slug_of(prompt)
  return type(prompt) == "string" and prompt:match "%.superpowers/([%w%._%-]+)/" or nil
end

local WRITES = { Write = true, Edit = true, MultiEdit = true, NotebookEdit = true }

-- Per transcript: how far it has been read, a cut-off last line, and the .superpowers
-- folders its Claude wrote into. Only what was added since is read each time.
local scanned = {}

local function note_writes(entry, slugs)
  local content = type(entry) == "table" and type(entry.message) == "table" and entry.message.content
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" and block.type == "tool_use" and WRITES[block.name] then
      local input = type(block.input) == "table" and block.input or {}
      local path = input.file_path or input.notebook_path
      local slug = type(path) == "string" and path:match "%.superpowers/([^/]+)/"
      if slug then
        slugs[slug] = true
      end
    end
  end
end

-- Calls done(slugs) with the .superpowers folders the transcript at `path` has writes
-- into ({ [slug] = true }). Reads without blocking; only lines that mention
-- superpowers are decoded.
function M.scan(path, done)
  local cache = scanned[path] or { offset = 0, rest = "", slugs = {} }
  scanned[path] = cache
  vim.uv.fs_open(path, "r", 438, function(err, fd)
    if err then
      return done(cache.slugs)
    end
    vim.uv.fs_fstat(fd, function(_, stat)
      local size = stat and stat.size or 0
      if size < cache.offset then
        -- Rewritten from scratch: start again.
        cache.offset, cache.rest, cache.slugs = 0, "", {}
      end
      vim.uv.fs_read(fd, size - cache.offset, cache.offset, function(_, data)
        vim.uv.fs_close(fd)
        data = cache.rest .. (data or "")
        cache.offset = size
        local last_break = data:match ".*()\n"
        cache.rest = last_break and data:sub(last_break + 1) or data
        local whole = last_break and data:sub(1, last_break - 1) or ""
        for line in whole:gmatch "[^\n]+" do
          -- Not ".superpowers/": a JSON writer may escape the slash.
          if line:find("superpowers", 1, true) and line:find("tool_use", 1, true) then
            local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
            if ok then
              note_writes(entry, cache.slugs)
            end
          end
        end
        done(cache.slugs)
      end)
    end)
  end)
end

local function yes_no(prompt, on_yes)
  vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
    if choice == "Yes" then
      on_yes()
    end
  end)
end

-- With the owner found (or not): asks once.
local function suggest(uid, slug, owner)
  local floatterm = ft()
  local me = M.by_uid(uid)
  if not me or me.parent_uid or me.workstream_asked then
    return
  end
  owner = owner and M.by_uid(owner.uid)
  if not owner then
    -- No tab wrote there: another that was pointed at the same folder.
    for _, other in ipairs(floatterm.tabs()) do
      if other ~= me and other.workstream_slug == slug then
        owner = M.parent(other)
        if not owner then
          floatterm.update(me.buf, { workstream_asked = true })
          yes_no(("Group with %s under a new '%s' group?"):format(floatterm.name(other), slug), function()
            local group = floatterm.new_group { label = slug, cwd = other.cwd, before = other.buf }
            M.set_parent(other.buf, group)
            M.set_parent(me.buf, group)
          end)
          return
        end
        break
      end
    end
  end
  if not owner then
    return
  end
  floatterm.update(me.buf, { workstream_asked = true })
  yes_no(("This looks like part of %s (%s). Make it a child?"):format(floatterm.name(owner), slug), function()
    M.set_parent(me.buf, owner.buf)
  end)
end

-- Called by lua/floatterm/claude with a Claude tab's first prompt (in full).
function M.on_prompt(record, prompt)
  local slug = M.slug_of(prompt)
  if not slug or record.parent_uid or record.workstream_asked then
    return
  end
  local floatterm = ft()
  floatterm.update(record.buf, { workstream_slug = slug })
  local others = vim.tbl_filter(function(other)
    return other ~= record and other.kind == "claude" and type(other.transcript_path) == "string"
  end, floatterm.tabs())
  local uid = record.uid
  local found, waiting = {}, #others
  local function finish()
    -- The first in tab order that wrote there.
    for _, other in ipairs(others) do
      if found[other] then
        return suggest(uid, slug, other)
      end
    end
    suggest(uid, slug, nil)
  end
  if waiting == 0 then
    return vim.schedule(finish)
  end
  for _, other in ipairs(others) do
    M.scan(other.transcript_path, function(slugs)
      vim.schedule(function()
        found[other] = slugs[slug] == true
        waiting = waiting - 1
        if waiting == 0 then
          finish()
        end
      end)
    end)
  end
end

-- The dossier ------------------------------------------------------------------

-- What lua/floatterm/claude_notes M.render adds for a tab: part_of = { name, uid } for
-- a child, workstreams = { rows } for a parent, each row { uid, name, status,
-- needs_you, now, done, total, percent, tasks } from the child's record and its
-- Claude notes (read with `read_sheet(note_id)`, { data } or { lines }).
function M.dossier_opts(record, read_sheet)
  local opts = {}
  if not (record and package.loaded["floatterm"]) then
    return opts
  end
  local floatterm = ft()
  read_sheet = read_sheet or require("floatterm.notes").claude_sheet
  local parent = M.parent(record)
  if parent then
    opts.part_of = { name = floatterm.name(parent), uid = parent.uid }
  end
  local children = M.children(record)
  if #children > 0 then
    local claude_notes = require "floatterm.claude_notes"
    local rows = {}
    for _, child in ipairs(children) do
      local row = {
        uid = child.uid,
        name = floatterm.name(child),
        status = child.status,
        needs_you = child.status == "needs_you" and (child.needs_you_message or "") or nil,
        now = "",
      }
      local ok, sheet = pcall(read_sheet, child.note_id)
      if child.note_id and ok and sheet and sheet.data then
        local data = claude_notes.normalise(sheet.data)
        row.now = data.now
        if #data.tasks > 0 then
          row.tasks = data.tasks
          row.percent, row.done, row.total = claude_notes.progress(data.tasks)
        end
      end
      table.insert(rows, row)
    end
    opts.workstreams = rows
  end
  return opts
end

-- For the tab bar, so this module is loaded (and next/previous and moves use it).
function M.setup() end

local group = api.nvim_create_augroup("floatterm_groups", { clear = true })
api.nvim_create_autocmd("User", {
  group = group,
  pattern = "FloatTermTabsChanged",
  callback = tidy_soon,
})
api.nvim_create_autocmd("User", {
  group = group,
  pattern = "FloatTermTabChanged",
  callback = function(args)
    if vim.tbl_contains(args.data.fields or {}, "parent_uid") then
      tidy_soon()
    end
  end,
})

-- For tests.
M.scanned = scanned

return M
