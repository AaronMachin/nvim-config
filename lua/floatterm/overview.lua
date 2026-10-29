-- Every Claude tab in this nvim in one picker, whatever folder or worktree each is in.
--
-- A row is the tab's state as the tab bar shows it, its name, its folder (the
-- worktree's, when it's in one) and the first line of its Claude notes' summary. Tabs
-- that need you come first, then working, then done, then by name. The preview is the
-- tab's Claude notes at the preview's width, with what it's asking on top while it
-- waits. Enter shows the tab; Ctrl+o opens its PR in the browser (a GitHub pull request
-- link first, else the first link in its PRs).

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

local function is_pr(url)
  return url:match "^https://github%.com/[^/]+/[^/]+/pull/%d+" ~= nil
end

-- The PR to open: the first GitHub pull request link, else the first link. From the
-- data's PRs, else the URLs in the .md's "# PRs" list.
local function first_pr(sheet)
  if not sheet then
    return nil
  end
  local urls = {}
  if sheet.data then
    for _, pr in ipairs(type(sheet.data.prs) == "table" and sheet.data.prs or {}) do
      local url = type(pr) == "table" and type(pr.url) == "string" and tidy_url(vim.trim(pr.url)) or ""
      if url:match "^https?://" then
        table.insert(urls, url)
      end
    end
  else
    local in_prs = false
    for _, line in ipairs(sheet.lines) do
      if line:match "^#%s" then
        in_prs = line:match "^#%s+PRs" ~= nil
      elseif in_prs then
        for url in line:gmatch "https?://[^%s<>]+" do
          table.insert(urls, tidy_url(url))
        end
      end
    end
  end
  for _, url in ipairs(urls) do
    if is_pr(url) then
      return url
    end
  end
  return urls[1]
end

-- Every Claude tab, in the order the picker lists them.
function M.list()
  local items = {}
  for _, record in ipairs(floatterm().tabs()) do
    if record.kind == "claude" then
      local summary = record.note_id and select(1, require("floatterm.notes").claude_summary(record.note_id)) or ""
      table.insert(items, {
        record = record,
        name = floatterm().name(record),
        folder = folder_of(record.cwd),
        summary = summary,
      })
    end
  end
  table.sort(items, function(a, b)
    local ra, rb = ORDER[a.record.status] or 4, ORDER[b.record.status] or 4
    if ra ~= rb then
      return ra < rb
    end
    return a.name:lower() < b.name:lower()
  end)
  return items
end

-- The preview's lines and highlights at `width`: what Claude is asking (while it waits)
-- on top, then its notes drawn as the notes pane draws them, PRs included.
function M.preview_lines(item, width)
  local claude_notes = require "floatterm.claude_notes"
  local record = item.record
  local lines, highlights = {}, {}
  if record.status == "needs_you" then
    local line, group = claude_notes.needs_you_line(record.needs_you_message)
    lines = { line, "" }
    highlights = { { line = 0, col = 0, end_col = #line, group = group } }
  end
  local sheet = sheet_of(record)
  local body, body_highlights
  if sheet and sheet.data then
    body, body_highlights = require("floatterm.notes").split_lines(claude_notes.render(sheet.data, { width = width }))
  elseif sheet then
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
    name_width = math.max(name_width, vim.fn.strdisplaywidth(item.name))
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
              return displayer {
                { text, hl },
                item.name,
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
