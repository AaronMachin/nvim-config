-- Every Claude tab in this nvim in one picker, whatever folder or worktree each is in.
--
-- A row is the tab's state as the tab bar shows it, its name, its folder (the
-- worktree's, when it's in one) and from its Claude notes the title and what Claude is
-- doing now (older notes without them: the summary's first line). Tabs that need you
-- come first, then working, then done, then by name. A tab under a parent
-- (lua/floatterm/groups) is listed indented under it, and a parent with its children
-- sorts by the most urgent of them; a group heading is listed as the parent of its
-- Claude tabs. The preview is the tab's Claude
-- notes drawn as the notes pane draws them, at the preview's width, with what it's
-- asking in the header while it waits. Enter shows the tab; Ctrl+o opens its PR in the
-- browser: the first link whose title or URL looks like a pull request, else the first
-- link.

local M = {}

local api = vim.api

local ORDER = { needs_you = 1, working = 2, done = 3 }
local NO_NOTES = "No Claude notes for this tab yet"
local HINTS = "Enter shows the tab · Ctrl+o opens its PR"

local function floatterm()
  return require "floatterm"
end

local function elapsed(since)
  local seconds = math.max(0, os.time() - since)
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

-- "◌ working · 4m", and its highlight, as in the tab bar.
local function state_text(record)
  local state = require("floatterm.tabbar").state(record)
  local text = state.glyph .. " " .. state.word
  if record.status and record.status_since then
    text = text .. " · " .. elapsed(record.status_since)
  end
  return text, state.hl
end

-- The worktree the tab is in (a worktree's .git is a file, which vim.fs.root finds
-- too), else the folder it started in.
local function folder_of(cwd)
  local root = vim.fs.root(cwd, ".git")
  return vim.fs.basename(root or cwd)
end

-- The tab's Claude notes as read now: { data } or { lines }, or nil without a note.
local function sheet_of(record)
  if not record.note_id then
    return nil
  end
  local sheet = require("floatterm.notes").claude_sheet(record.note_id)
  if not sheet.data and #sheet.lines == 0 then
    return nil
  end
  return sheet
end

-- A URL as written in text, without the punctuation that ends a sentence or bracket
-- round it.
local function tidy_url(url)
  return (url:gsub("[%.,;:!%?%)%]>'\"`]+$", ""))
end

-- A GitHub pull request link, or a title that says it's one ("PR #231 cloud/console").
local function is_pr(link)
  return link.url:match "^https?://github%.com/[^/]+/[^/]+/pull/%d+" ~= nil
    or link.title:match "%f[%w]PR%f[%W]" ~= nil
    or link.title:lower():find("pull request", 1, true) ~= nil
end

-- Sections of an old-format or plain-text .md whose URLs are links.
local LINK_HEADINGS = { "^#%s+PRs", "^#%s+Key links", "^Links$" }

-- The PR to open: the first link that looks like a pull request, else the first link.
-- From the data's links (older data's PRs first), else the URLs in the .md's link
-- sections, each line as its title.
local function first_pr(sheet)
  if not sheet then
    return nil
  end
  local links = {}
  if sheet.data then
    for _, link in ipairs(require("floatterm.claude_notes").normalise(sheet.data).links) do
      table.insert(links, { title = link.title, url = tidy_url(link.url) })
    end
  else
    -- A section is its heading and the list right under it.
    local in_links = false
    for _, line in ipairs(sheet.lines) do
      if not line:match "^%s*[-*] " then
        in_links = false
        for _, heading in ipairs(LINK_HEADINGS) do
          in_links = in_links or line:match(heading) ~= nil
        end
      elseif in_links then
        -- The line's text without its URLs, so a PR's title is told apart from a link
        -- mentioned beside it.
        local title = line:gsub("https?://[^%s<>]+", "")
        for url in line:gmatch "https?://[^%s<>]+" do
          table.insert(links, { title = title, url = tidy_url(url) })
        end
      end
    end
  end
  for _, link in ipairs(links) do
    if is_pr(link) then
      return link.url
    end
  end
  return links[1] and links[1].url
end

local function rank(record)
  return ORDER[record.status] or 4
end

-- Every Claude tab, in the order the picker lists them: each item { record, name,
-- folder, summary, depth }.
function M.list()
  local groups = require "floatterm.groups"
  local items = {}
  local by_record = {}
  for _, record in ipairs(floatterm().tabs()) do
    -- A group heading is listed when a Claude tab is somewhere under it.
    local listed = record.kind == "claude"
    if record.kind == "group" then
      for _, other in ipairs(floatterm().tabs()) do
        listed = listed or (other.kind == "claude" and groups.is_under(other, record))
      end
    end
    if listed then
      local summary = ""
      if record.note_id then
        local first, _, claude = require("floatterm.notes").claude_summary(record.note_id)
        local parts = vim.tbl_filter(function(part)
          return part ~= ""
        end, { claude.title, claude.now })
        summary = #parts > 0 and table.concat(parts, " · ") or first
      end
      local item = {
        record = record,
        name = floatterm().name(record),
        folder = folder_of(record.cwd),
        summary = summary,
        children = {},
      }
      by_record[record] = item
      table.insert(items, item)
    end
  end
  -- Under the nearest listed ancestor; the rest are top-level.
  local tops = {}
  for _, item in ipairs(items) do
    local parent = groups.parent(item.record)
    local seen = 0
    while parent and not by_record[parent] and seen < 100 do
      parent = groups.parent(parent)
      seen = seen + 1
    end
    if parent and by_record[parent] then
      table.insert(by_record[parent].children, item)
    else
      table.insert(tops, item)
    end
  end
  -- A parent counts as urgent as the most urgent tab under it (a group heading has no
  -- state of its own).
  local function urgency(item)
    local best = item.record.kind == "group" and 5 or rank(item.record)
    for _, child in ipairs(item.children) do
      best = math.min(best, urgency(child))
    end
    item.urgency = best
    return best
  end
  local function by_urgency(a, b)
    if a.urgency ~= b.urgency then
      return a.urgency < b.urgency
    end
    return a.name:lower() < b.name:lower()
  end
  local ordered = {}
  local function add(list, depth)
    for _, item in ipairs(list) do
      urgency(item)
    end
    table.sort(list, by_urgency)
    for _, item in ipairs(list) do
      item.depth = depth
      table.insert(ordered, item)
      add(item.children, depth + 1)
      item.children = nil
    end
  end
  add(tops, 0)
  return ordered
end

-- The preview's lines and highlights at `width`: its notes drawn as the notes pane
-- draws them, with the tab's state (what Claude is asking, while it waits) in the
-- header. An old-format sheet or none has what it's asking on top instead.
function M.preview_lines(item, width)
  local claude_notes = require "floatterm.claude_notes"
  local record = item.record
  if record.kind == "group" then
    -- Only its workstreams to show.
    local related = require("floatterm.groups").dossier_opts(record)
    local lines, highlights = claude_notes.render(
      { title = item.name },
      { width = width, workstreams = related.workstreams }
    )
    return lines, highlights
  end
  local sheet = sheet_of(record)
  if sheet and sheet.data then
    return require("floatterm.notes").claude_preview(record.note_id, width, record)
  end
  local lines, highlights = {}, {}
  if record.status == "needs_you" then
    local line, group = claude_notes.needs_you_line(record.needs_you_message)
    lines = { line, "" }
    highlights = { { line = 0, col = 0, end_col = #line, group = group } }
  end
  local body, body_highlights
  if sheet then
    body, body_highlights = sheet.lines, {}
  else
    body, body_highlights = { NO_NOTES }, { { line = 0, col = 0, end_col = #NO_NOTES, group = "Comment" } }
  end
  local offset = #lines
  vim.list_extend(lines, body)
  for _, hl in ipairs(body_highlights) do
    table.insert(highlights, { line = hl.line + offset, col = hl.col, end_col = hl.end_col, group = hl.group })
  end
  return lines, highlights
end

-- <leader>aa: the picker.
function M.pick()
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("floatterm: the Claude overview needs telescope", vim.log.levels.WARN)
    return
  end
  local items = M.list()
  if #items == 0 then
    vim.notify("No Claude tabs open", vim.log.levels.INFO)
    return
  end

  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local previewers = require "telescope.previewers"
  local preview_utils = require "telescope.previewers.utils"
  local entry_display = require "telescope.pickers.entry_display"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"

  local state_width, name_width, folder_width = 0, 4, 6
  for _, item in ipairs(items) do
    state_width = math.max(state_width, vim.fn.strdisplaywidth((state_text(item.record))))
    name_width = math.max(name_width, vim.fn.strdisplaywidth(item.name) + 2 * item.depth)
    folder_width = math.max(folder_width, vim.fn.strdisplaywidth(item.folder))
  end
  local displayer = entry_display.create {
    separator = "  ",
    items = {
      { width = state_width },
      { width = math.min(name_width, 28) },
      { width = math.min(folder_width, 24) },
      { remaining = true },
    },
  }

  local ns = api.nvim_create_namespace "floatterm_overview"
  local function preview(self, entry)
    local buf, win = self.state.bufnr, self.state.winid
    local width = win and api.nvim_win_is_valid(win) and api.nvim_win_get_width(win) or 60
    local lines, highlights = M.preview_lines(entry.value, width)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    preview_utils.highlighter(buf, "markdown")
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, hl in ipairs(highlights) do
      -- Above markdown's own highlighting, which takes the bar for a link.
      pcall(api.nvim_buf_set_extmark, buf, ns, hl.line, hl.col, {
        end_col = hl.end_col,
        hl_group = hl.group,
        priority = 200,
      })
    end
    if win and api.nvim_win_is_valid(win) then
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true
    end
  end

  pickers
    .new({}, {
      prompt_title = "Claude tabs",
      finder = finders.new_table {
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = table.concat({ item.name, item.folder, item.summary, item.record.status or "" }, " "),
            display = function()
              local text, hl = state_text(item.record)
              -- A group heading has no state of its own.
              if item.record.kind == "group" then
                text, hl = "▾ group", "FloatTermGroup"
              end
              return displayer {
                { text, hl },
                string.rep("  ", item.depth - 1) .. (item.depth > 0 and "└ " or "") .. item.name,
                { item.folder, "Comment" },
                item.summary,
              }
            end,
          }
        end,
      },
      -- Keeps the order above (state, then name) until you type.
      sorter = conf.generic_sorter {},
      previewer = previewers.new_buffer_previewer {
        title = HINTS,
        define_preview = preview,
      },
      attach_mappings = function(prompt_buf, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_buf)
          if entry then
            -- After telescope has put the cursor back, so the tab opens typing.
            vim.schedule(function()
              if not floatterm().focus_buf(entry.value.record.buf) then
                vim.notify("floatterm: that tab has closed", vim.log.levels.INFO)
              end
            end)
          end
        end)
        map({ "i", "n" }, "<C-o>", function()
          local entry = action_state.get_selected_entry()
          if not entry then
            return
          end
          -- Read again: the notes may have gained a PR since the picker opened.
          local url = first_pr(sheet_of(entry.value.record))
          if url then
            vim.ui.open(url)
          else
            vim.notify("No PR in " .. entry.value.name .. "'s notes", vim.log.levels.INFO)
          end
        end)
        return true
      end,
    })
    :find()
end

-- For tests.
M.first_pr = first_pr

return M
