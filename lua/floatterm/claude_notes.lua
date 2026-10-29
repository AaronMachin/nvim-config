-- Claude's half of a Claude tab's notes: a dossier of the session kept up to date by a
-- small, cheap Claude (the claude_notes_model setting, haiku by default) after each
-- turn. The claude_notes setting switches it off everywhere.
--
-- When the tab's Claude finishes a turn (the Stop hook, through lua/floatterm/claude)
-- and the tab has notes on, the turn is read from Claude Code's transcript (from the
-- last prompt to the end: the prompt, Claude's replies, and the tools it ran with a
-- short result) and given to `claude -p` with the current dossier, which it rewrites as
-- data in a fixed schema: a title, what it's doing now, hashtags, the plan's tasks, the
-- tickets and PRs it touched, decisions and details. Anything that looks like a secret
-- (tokens, keys, passwords) is replaced with [redacted] before it's sent; links are
-- kept, but for the values of parameters such as ?token= in them. Claude's structured
-- reply is written beside the user's own notes (floatterm.notes.paths) as
-- <note_id>.claude.json, which M.render draws at the pane's width with plain text and
-- highlights, and as plain text with the URLs written out (M.text) in
-- <note_id>.claude.md, for Claude in the tab to read and as the next run's current
-- dossier. FloatTermClaudeNotesChanged is then fired with the note_id so the pane can
-- reload it. The percentage is worked out from the tasks, not asked for.
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
You keep a short dossier for a developer about a Claude Code session running in one of their terminal tabs. You are given the current dossier and the latest turn of the session: the user's prompt, Claude's replies, and the tools Claude ran with short results. Reply with the updated dossier as data in the given schema:

- title: the session's ticket key and a short title, e.g. "SD-494 · Console partner sign-in". Without a ticket, just the short title. Keep it stable between turns unless the work changed.
- summary: one or two short lines on what this session is about and where it is. Simple, key words.
- now: a few words on what Claude is doing right now, e.g. "Task 1: schema, model and factory".
- hashtags: up to 10 one-word categories for the session (no # needed), e.g. auth, cognito, deploy.
- tasks: the session's plan as tasks, in order, each with a short name and a state (done, in_progress, pending, blocked), and for in_progress or blocked a few words on what it is doing or what blocks it. Keep the tasks and their names stable between turns unless the work changed.
- links: the tickets Claude created, updated or is working on (this session's ticket first) and the pull requests it made, pushed to or is reviewing. Each with its full URL, a short title ("SD-494 · this session's ticket", "PR #231 cloud/console") and a one or two word note on what happened to it ("In development", "Created", "Opened", "Reviewing", "Merged"). Never homepages, site roots or generic wiki roots. Other useful links go in details with their URL.
- decisions: decisions made in the session and why, one terse line each.
- details: anything else worth keeping, as terse lines: branch and commits, what's waiting on whom, other useful links with their URL.

Keep what is still true from the current dossier, update what this turn changed, and drop what is stale or routine. Never invent a link or a task that isn't in the input. Keep decisions and details to about 10 lines each. No emoji. UK English.]]

-- The shape Claude has to reply in (claude -p --json-schema), so the dossier's layout
-- is drawn here and can't drift: the bar, the plan and the links are always right.
local SCHEMA = {
  type = "object",
  properties = {
    title = { type = "string" },
    summary = { type = "string" },
    now = { type = "string" },
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
    links = {
      type = "array",
      items = {
        type = "object",
        properties = {
          title = { type = "string" },
          url = { type = "string", pattern = "^https?://" },
          note = { type = "string" },
        },
        required = { "title", "url", "note" },
      },
    },
    decisions = { type = "array", items = { type = "string" } },
    details = { type = "array", items = { type = "string" } },
  },
  required = { "title", "summary", "now", "hashtags", "tasks", "links", "decisions", "details" },
}

-- Plain symbols, one cell wide in any font (emoji aren't, and don't line up).
local SYMBOLS = {
  done = { "✓", "DiagnosticOk", "done" },
  in_progress = { "▸", "DiagnosticInfo", "in progress" },
  pending = { "·", "Comment", "pending" },
  blocked = { "!", "DiagnosticError", "blocked" },
}
-- The tab's state, as the tab bar shows it.
local STATES = {
  needs_you = { "●", "needs you", "FloatTermNeedsYou" },
  working = { "◌", "working", "FloatTermWorking" },
  done = { "✓", "done", "FloatTermDone" },
}
-- The folded sections at the bottom, in order, with the key that opens each.
M.FOLDS = {
  { name = "decisions", label = "Decisions", key = "d" },
  { name = "details", label = "Details", key = "t" },
}
-- What each task counts for in the percentage: half for one under way.
local WORTH = { done = 1, in_progress = 0.5 }
-- No one-eighth block: next to the empty part it reads as the bar's end.
local EIGHTHS = { "", "", "▎", "▍", "▌", "▋", "▊", "▉" }
local DEFAULT_WIDTH = 60
-- More tasks than this and the done ones fold into one line, so the current and next
-- ones stay in view. Still more, and the last ones become a count, so no more than
-- this many task rows show.
local FOLD_OVER = 6
-- Between the two columns of LINKS and PLAN.
local GAP = 2
local NEEDS_YOU_HL = "FloatTermNeedsYou"
local LINK_HL = "FloatTermNotesLink"
local HEADING_HL = "FloatTermNotesHeading"
local TITLE_HL = "FloatTermNotesTitle"

local function set_highlights()
  local function fg(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
  end
  vim.api.nvim_set_hl(0, LINK_HL, { fg = fg "Function" or fg "Identifier", underline = true, default = true })
  vim.api.nvim_set_hl(0, HEADING_HL, { fg = fg "Comment", bold = true, default = true })
  vim.api.nvim_set_hl(0, TITLE_HL, { bold = true, default = true })
  vim.api.nvim_set_hl(0, "FloatTermNotesCurrent", { link = "Visual", default = true })
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("floatterm_claude_notes_hl", { clear = true }),
  callback = set_highlights,
})

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

-- The line shown while the tab's Claude waits on you, where there's no dossier to put
-- it in (an old-format sheet).
function M.needs_you_line(message)
  message = text(message):gsub("%s+", " ")
  return "● needs you" .. (message ~= "" and (" · " .. message) or ""), NEEDS_YOU_HL
end

local function lines_of(list)
  local out = {}
  for _, line in ipairs(type(list) == "table" and list or {}) do
    line = one_line(line):gsub("^[-*]%s*", "")
    if line ~= "" then
      table.insert(out, line)
    end
  end
  return out
end

-- Claude's reply in the current shape, whichever shape it was written in: older ones
-- had `prs` and `links` without a note, and no title, now or decisions. A title falls
-- back to the summary's first line, and now to the task under way.
function M.normalise(data)
  data = type(data) == "table" and data or {}
  local out = {
    title = one_line(data.title),
    summary = text(data.summary),
    now = one_line(data.now),
    hashtags = {},
    tasks = {},
    links = {},
    decisions = lines_of(data.decisions),
    details = lines_of(data.details),
  }
  for _, tag in ipairs(type(data.hashtags) == "table" and data.hashtags or {}) do
    tag = text(tag):gsub("^#+", ""):gsub("%s+", "-")
    if tag ~= "" and #out.hashtags < 10 then
      table.insert(out.hashtags, "#" .. tag)
    end
  end
  for _, task in ipairs(type(data.tasks) == "table" and data.tasks or {}) do
    if type(task) == "table" and text(task.name) ~= "" then
      local state = SYMBOLS[task.state] and task.state or "pending"
      table.insert(out.tasks, { name = one_line(task.name), state = state, detail = one_line(task.detail) })
    end
  end
  -- Only entries with a real URL, each once: a link without one isn't worth showing.
  local seen = {}
  for _, list in ipairs { data.prs or {}, data.links or {} } do
    for _, entry in ipairs(type(list) == "table" and list or {}) do
      local url = type(entry) == "table" and text(entry.url) or ""
      if url:match "^https?://" and not seen[url] then
        seen[url] = true
        local title = one_line(entry.title)
        table.insert(out.links, { title = title ~= "" and title or url, url = url, note = one_line(entry.note) })
      end
    end
  end
  if out.title == "" then
    out.title = vim.trim(vim.split(out.summary, "\n", { plain = true })[1] or "")
  end
  if out.now == "" then
    for _, task in ipairs(out.tasks) do
      if task.state == "in_progress" then
        out.now = task.name
        break
      end
    end
  end
  return out
end

-- The bar's filled and empty parts, `cells` wide, in eighths of a cell.
local function bar_parts(percent, cells)
  local eighths = math.floor(cells * 8 * percent / 100)
  local full, part = math.floor(eighths / 8), EIGHTHS[eighths % 8 + 1]
  local filled = string.rep("█", full) .. part
  return filled, string.rep("░", cells - full - (part ~= "" and 1 or 0))
end

local function bar_colour(tasks)
  local colour = "DiagnosticOk"
  for _, task in ipairs(tasks) do
    if task.state == "blocked" then
      return "DiagnosticError"
    elseif task.state == "in_progress" then
      colour = "DiagnosticInfo"
    end
  end
  return colour
end

-- The tasks the plan shows: past FOLD_OVER the done ones fold into one row and the
-- last ones into a count. Rows are tasks, or { folded = n } / { more = n }.
local function plan_rows(tasks)
  if #tasks <= FOLD_OVER then
    return tasks
  end
  local shown = vim.tbl_filter(function(task)
    return task.state ~= "done"
  end, tasks)
  local folded = #tasks - #shown
  local rows = folded > 0 and { { folded = folded } } or {}
  -- Room for the folded row and the count, the rest for the first tasks left.
  local room = FOLD_OVER - #rows
  if #shown > room then
    vim.list_extend(rows, vim.list_slice(shown, 1, room - 1))
    table.insert(rows, { more = #shown - (room - 1) })
  else
    vim.list_extend(rows, shown)
  end
  return rows
end

-- `s` broken at spaces into lines of `width` cells, the first after `first`, the rest
-- after `indent` (a hanging indent). A word longer than a line is broken where it has
-- to be.
local function wrap(s, width, first, indent)
  local out, line = {}, first
  for word in s:gmatch "%S+" do
    local sep = line == first and "" or " "
    if width_of(line .. sep .. word) <= width then
      line = line .. sep .. word
    else
      if line ~= first and line ~= indent then
        table.insert(out, line)
        line = indent
      end
      while width_of(line .. word) > width do
        local room = width - width_of(line)
        local piece = vim.fn.strcharpart(word, 0, math.max(1, room))
        table.insert(out, line .. piece)
        word = vim.fn.strcharpart(word, vim.fn.strchars(piece))
        line = indent
      end
      line = line .. word
    end
  end
  if line ~= first and line ~= indent then
    table.insert(out, line)
  end
  return out
end

-- The dossier, drawn with plain text and highlights to fit `width` cells. Returns the
-- lines, their highlights ({ line, col, end_col, group }, 0-based bytes) and what can
-- be acted on: { kind = "link", line, col, end_col, url, title } for each link, and
-- { kind = "fold", name, line, col, end_col } for each fold toggle. opts:
--   width      the text width (DEFAULT_WIDTH)
--   status     the tab's status (needs_you, working, done), or nil outside a tab
--   needs_you  what the tab's Claude is asking while it waits ("" without a message)
--   open       { decisions = true, details = true } for the folds shown open
function M.render(data, opts)
  opts = opts or {}
  data = M.normalise(data)
  local width = math.max(10, opts.width or DEFAULT_WIDTH)
  local open = opts.open or {}
  local lines, highlights, targets = {}, {}, {}
  local function add(line)
    table.insert(lines, line)
    return #lines - 1
  end
  local function highlight(row, col, end_col, group)
    if group and end_col > col then
      table.insert(highlights, { line = row, col = col, end_col = end_col, group = group })
    end
  end
  local function heading(name)
    if #lines > 0 then
      add ""
    end
    highlight(add(" " .. name), 1, 1 + #name, HEADING_HL)
  end

  -- Header: the title, the state with what Claude is doing and the bar, the hashtags.
  if data.title ~= "" then
    local title = fit(data.title, width - 3)
    local row = add(" ✳ " .. title)
    highlight(row, #" ✳ ", #" ✳ " + #title, TITLE_HL)
  end

  local bar, bar_hls = nil, {}
  if #data.tasks > 0 then
    local percent = percent_of(data.tasks)
    local filled, empty = bar_parts(percent, math.max(6, math.min(20, math.floor(width / 6))))
    bar = "▕" .. filled .. empty .. "▏" .. (" %d%%"):format(percent)
    local start = #"▕"
    bar_hls = {
      { 0, start, "Comment" },
      { start, start + #filled, bar_colour(data.tasks) },
      { start + #filled, start + #filled + #empty, "Comment" },
      { start + #filled + #empty, start + #filled + #empty + #"▏", "Comment" },
    }
  end
  -- The left part as pieces { text, group }, cut together to the room left of the bar.
  local pieces = {}
  local asking = opts.status == "needs_you" or opts.needs_you ~= nil
  if asking then
    local message = text(opts.needs_you):gsub("%s+", " ")
    table.insert(pieces, { "● " .. (message ~= "" and message or "needs you"), NEEDS_YOU_HL })
  elseif STATES[opts.status] then
    local state = STATES[opts.status]
    table.insert(pieces, { state[1] .. " " .. state[2], state[3] })
    if data.now ~= "" then
      table.insert(pieces, { " · " .. data.now })
    end
  elseif data.now ~= "" then
    table.insert(pieces, { data.now })
  end
  local room = width - 1 - (bar and (width_of(bar) + GAP) or 0)
  -- Too narrow for both: the bar goes on a line of its own.
  local own_line = bar and #pieces > 0 and room < 12
  if own_line then
    room = width - 1
  end
  if #pieces > 0 then
    local line, row = " ", #lines
    for _, piece in ipairs(pieces) do
      local left = room - width_of(line) + 1
      if left <= 0 then
        break
      end
      local part = fit(piece[1], left)
      if piece[2] then
        highlight(row, #line, #line + #part, piece[2])
      end
      line = line .. part
    end
    if bar and not own_line then
      local pad = width - width_of(line) - width_of(bar)
      line = line .. string.rep(" ", pad)
      for _, hl in ipairs(bar_hls) do
        highlight(row, #line + hl[1], #line + hl[2], hl[3])
      end
      line = line .. bar
      bar = nil
    end
    add(line)
  end
  if bar then
    local line = string.rep(" ", math.max(1, width - width_of(bar)))
    local row = add(line .. bar)
    for _, hl in ipairs(bar_hls) do
      highlight(row, #line + hl[1], #line + hl[2], hl[3])
    end
  end
  if #data.hashtags > 0 then
    local line = " "
    for _, tag in ipairs(data.hashtags) do
      local next = line == " " and (line .. tag) or (line .. " " .. tag)
      if width_of(next) > width then
        break
      end
      line = next
    end
    if line ~= " " then
      highlight(add(line), 1, #line, "Comment")
    end
  end

  -- Two columns, the right one starting in one column for every row. Each row is
  -- { prefix, prefix_group, left, left_group, right, right_group }; the left side is
  -- cut first, as the notes are short, then the right with … to what's left.
  local function columns(rows)
    local avail = width - 2
    local widest_left, widest_right = 0, 0
    for _, r in ipairs(rows) do
      widest_left = math.max(widest_left, width_of(r.prefix .. r.left))
      widest_right = math.max(widest_right, width_of(r.right))
    end
    local column = widest_left
    if widest_left + GAP + widest_right > avail then
      local right_room = math.min(widest_right, math.max(6, math.floor(avail * 0.4)))
      column = math.max(1, math.min(widest_left, avail - GAP - right_room))
    end
    local out = {}
    for _, r in ipairs(rows) do
      local line, row = "  ", #lines
      if r.prefix ~= "" then
        highlight(row, #line, #line + #r.prefix, r.prefix_group)
        line = line .. r.prefix
      end
      local left = fit(r.left, math.max(1, column - width_of(r.prefix)))
      highlight(row, #line, #line + #left, r.left_group)
      line = line .. left
      local right_room = avail - column - GAP
      if r.right ~= "" and right_room >= 2 then
        line = line .. string.rep(" ", 2 + column - width_of(line) + GAP)
        local right = fit(r.right, right_room)
        highlight(row, #line, #line + #right, r.right_group)
        line = line .. right
      end
      add(line)
      table.insert(out, { row = row, col = 2 + #r.prefix, end_col = 2 + #r.prefix + #left })
    end
    return out
  end

  if #data.links > 0 then
    heading "LINKS"
    local rows = vim.tbl_map(function(link)
      return { prefix = "", left = link.title, left_group = LINK_HL, right = link.note, right_group = "Comment" }
    end, data.links)
    for i, placed in ipairs(columns(rows)) do
      local link = data.links[i]
      table.insert(targets, {
        kind = "link",
        line = placed.row,
        col = placed.col,
        end_col = placed.end_col,
        url = link.url,
        title = link.title,
      })
    end
  end

  if #data.tasks > 0 then
    heading "PLAN"
    local rows = {}
    for _, task in ipairs(plan_rows(data.tasks)) do
      if task.folded then
        table.insert(rows, {
          prefix = "✓ ",
          prefix_group = "DiagnosticOk",
          left = ("%d done"):format(task.folded),
          left_group = "Comment",
          right = "",
        })
      elseif task.more then
        table.insert(rows, {
          prefix = "· ",
          prefix_group = "Comment",
          left = ("%d more"):format(task.more),
          left_group = "Comment",
          right = "",
        })
      else
        local symbol = SYMBOLS[task.state]
        local right = task.detail
        if task.state == "blocked" then
          right = "blocked" .. (right ~= "" and (": " .. right) or "")
        end
        table.insert(rows, {
          prefix = symbol[1] .. " ",
          prefix_group = symbol[2],
          left = task.name,
          left_group = task.state == "pending" and "Comment" or nil,
          right = right,
          right_group = task.state == "blocked" and "DiagnosticError" or "Comment",
        })
      end
    end
    columns(rows)
  end

  -- Decisions and details: one line of toggles, folded by default, then whichever are
  -- open below it.
  local toggles = {}
  for _, fold in ipairs(M.FOLDS) do
    if #data[fold.name] > 0 then
      local label = ("%s %s (%d)"):format(open[fold.name] and "▾" or "▸", fold.label, #data[fold.name])
      table.insert(toggles, { fold = fold, label = label, text = label .. " " .. fold.key })
    end
  end
  if #toggles > 0 then
    add ""
    local together = " "
    for i, toggle in ipairs(toggles) do
      together = together .. (i > 1 and "   " or "") .. toggle.text
    end
    -- Too narrow for one line, a line each.
    local per_line = width_of(together) > width
    local line, row = " ", nil
    for i, toggle in ipairs(toggles) do
      if per_line and i > 1 then
        add(line)
        line = " "
      elseif i > 1 then
        line = line .. "   "
      end
      row = #lines
      local col = #line
      highlight(row, col + #toggle.label + 1, col + #toggle.text, "Comment")
      table.insert(targets, {
        kind = "fold",
        name = toggle.fold.name,
        line = row,
        col = col,
        end_col = col + #toggle.text,
      })
      line = line .. toggle.text
    end
    add(line)
    for _, toggle in ipairs(toggles) do
      local name = toggle.fold.name
      if open[name] then
        heading(toggle.fold.label:upper())
        for _, item in ipairs(data[name]) do
          for _, line in ipairs(wrap(item, width, "  - ", "    ")) do
            add(line)
          end
        end
      end
    end
  end
  return lines, highlights, targets
end

-- The dossier as plain text with the URLs written out, for Claude in the tab to read
-- and as the next run's current dossier.
function M.text(data)
  data = M.normalise(data)
  local lines = {}
  if data.title ~= "" then
    table.insert(lines, data.title)
  end
  if data.summary ~= "" then
    vim.list_extend(lines, vim.split(data.summary, "\n", { plain = true }))
  end
  if data.now ~= "" then
    table.insert(lines, "Now: " .. data.now)
  end
  if #data.hashtags > 0 then
    table.insert(lines, table.concat(data.hashtags, " "))
  end
  local function section(heading, items)
    if #items > 0 then
      if #lines > 0 then
        table.insert(lines, "")
      end
      table.insert(lines, heading)
      vim.list_extend(lines, items)
    end
  end
  section(
    "Links",
    vim.tbl_map(function(link)
      return ("- %s%s: %s"):format(link.title, link.note ~= "" and (" (" .. link.note .. ")") or "", link.url)
    end, data.links)
  )
  if #data.tasks > 0 then
    section(
      ("Plan (%d%% done)"):format(percent_of(data.tasks)),
      vim.tbl_map(function(task)
        local detail = task.detail ~= "" and (": " .. task.detail) or ""
        return ("- [%s] %s%s"):format(SYMBOLS[task.state][3], task.name, detail)
      end, data.tasks)
    )
  end
  local function bullets(items)
    return vim.tbl_map(function(item)
      return "- " .. item
    end, items)
  end
  section("Decisions", bullets(data.decisions))
  section("Details", bullets(data.details))
  return table.concat(lines, "\n")
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
    -- The structured reply, written out as plain text; Claude's own text only if a
    -- reply somehow came back without it.
    local data = type(out.structured_output) == "table" and out.structured_output or nil
    local sheet = data and M.text(data) or sheet_from(out.result)
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
    local input =
      redact("Current dossier:\n" .. (current ~= "" and current or "(empty)") .. "\n\nLatest turn:\n" .. turn)
    local model = settings.get "claude_notes_model"
    local command = {
      "claude",
      "-p",
      "Update the dossier from the turn below.",
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

-- Rewrites an old-format sheet (from before Claude's notes came as data) in the
-- current shape now, rather than at the tab's next turn. Quiet: nothing is said when
-- it can't run (no conversation yet, another tab keeps these notes).
function M.upgrade(record)
  if settings.get "claude_notes" and record and record.transcript_path and keeps(record) then
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
