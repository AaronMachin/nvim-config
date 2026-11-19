-- Labels you put on a tab from the tab bar: done, review, blocked, parked (the marks
-- setting), or your own. A tab has one at a time, kept on its record as `mark` (the
-- label's text) and saved with it by lua/floatterm/restore. A mark only changes how the
-- tab looks: nothing moves, folds or gets renamed.
--
-- The tab bar (lua/floatterm/tabbar) draws a mark as a block in its colour, and a tab
-- marked done in the dim colour all over. Your own labels get one of a few colours
-- picked from their text, so the same words always come out the same colour. The ones
-- you've typed are kept, the most recent first, in stdpath("data")/floatterm-marks.json
-- for `t e` to offer again.

local M = {}

local api = vim.api
local settings = require "floatterm.settings"

-- Your own labels are cut to this many characters.
M.MAX = 16
-- How many of your own labels are remembered.
M.RECENT = 20
-- A field so tests can point it somewhere else.
M.path = vim.fn.stdpath "data" .. "/floatterm-marks.json"

-- The colours a mark can be, each the foreground of a colour scheme group, used as the
-- block's background.
M.COLOURS = {
  green = "DiagnosticOk",
  blue = "DiagnosticInfo",
  red = "DiagnosticError",
  grey = "Comment",
  purple = "Statement",
  yellow = "DiagnosticWarn",
  cyan = "Special",
  orange = "Constant",
}
-- The colours your own labels are picked from.
local CUSTOM = { "purple", "cyan", "orange", "yellow" }

-- The fixed labels from the settings: each { key, word, colour }.
function M.labels()
  return settings.get "marks"
end

local function highlight_name(colour)
  return "FloatTermMark" .. colour:sub(1, 1):upper() .. colour:sub(2)
end

function M.set_highlights()
  local normal = api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal.bg then
    normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  end
  for colour, group in pairs(M.COLOURS) do
    local from = api.nvim_get_hl(0, { name = group, link = false })
    api.nvim_set_hl(0, highlight_name(colour), {
      fg = normal.bg or 0,
      bg = from.fg or 0x808080,
      bold = true,
      default = true,
    })
  end
  api.nvim_set_hl(0, "FloatTermMarkedDone", { link = "Comment", default = true })
end

-- The colour of `word`: its fixed label's, else one picked from its text.
function M.colour(word)
  for _, label in ipairs(M.labels()) do
    if label.word == word then
      return label.colour
    end
  end
  local sum = 0
  for i = 1, #word do
    sum = sum + word:byte(i)
  end
  return CUSTOM[sum % #CUSTOM + 1]
end

-- The block the tab bar draws for a record's mark: { text, hl }, or nil without one.
function M.chunk(record)
  local word = record and record.mark
  if type(word) ~= "string" or word == "" then
    return nil
  end
  local colour = M.colour(word)
  return { " " .. word .. " ", highlight_name(M.COLOURS[colour] and colour or "grey") }
end

function M.is_done(record)
  return record and record.mark == "done"
end

-- Puts `word` on the tab `buf` (nil or "" takes the mark off), cut to MAX characters.
function M.set(buf, word)
  word = word and vim.trim(word) or ""
  if vim.fn.strchars(word) > M.MAX then
    word = vim.fn.strcharpart(word, 0, M.MAX)
  end
  require("floatterm").update(buf, { mark = word ~= "" and word or vim.NIL })
end

-- `d`: done on, or off again.
function M.toggle_done(buf)
  local record = require("floatterm").record(buf)
  if record then
    M.set(buf, record.mark ~= "done" and "done" or nil)
  end
end

-- Your own labels, the most recent first.
function M.recent()
  local file = io.open(M.path, "r")
  if not file then
    return {}
  end
  local ok, list = pcall(vim.json.decode, file:read "*a")
  file:close()
  return ok and type(list) == "table" and list or {}
end

local function remember(word)
  local list = { word }
  for _, other in ipairs(M.recent()) do
    if other ~= word and #list < M.RECENT then
      table.insert(list, other)
    end
  end
  local file = io.open(M.path, "w")
  if file then
    file:write(vim.json.encode(list))
    file:close()
  end
end

-- For `t e`'s prompt: Tab completes from your recent labels.
function M.complete(lead)
  return vim.tbl_filter(function(word)
    return word:sub(1, #lead) == lead
  end, M.recent())
end

-- `t e`: asks for your own label for the tab `buf`.
function M.ask(buf)
  local record = require("floatterm").record(buf)
  if not record then
    return
  end
  vim.ui.input({
    prompt = "Label for " .. require("floatterm").name(record) .. ": ",
    completion = "customlist,v:lua.require'floatterm.marks'.complete_cmd",
  }, function(input)
    if input == nil then
      return
    end
    input = vim.trim(input)
    if input ~= "" then
      if vim.fn.strchars(input) > M.MAX then
        input = vim.fn.strcharpart(input, 0, M.MAX)
      end
      remember(input)
    end
    M.set(buf, input)
  end)
end

-- The same as M.complete, in the shape a customlist completion is called with.
function M.complete_cmd(lead)
  return M.complete(lead or "")
end

return M
