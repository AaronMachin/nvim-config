-- Reopens the floating terminal's tabs when nvim starts again in the same folder.
--
-- With the reopen_tabs setting on, quitting an nvim started in a folder (no files
-- given) saves its tabs to stdpath("data")/floatterm-tabs/<folder>.json; the last
-- nvim to quit in that folder wins. Starting nvim there again reopens them in the
-- background, without showing the float:
--   Claude tabs resume their conversation (`claude --resume <id>`) where it ran.
--   Shell tabs are fresh shells in the same folder. What last ran in one is kept on
--   the record as last_command, but never run again.
-- Opening nvim on a file (as git's editor, say) neither restores nor saves.

local M = {}

-- Fields rather than locals so tests can point them somewhere else.
M.dir = vim.fn.stdpath "data" .. "/floatterm-tabs"

local folder = nil
local done = false

local function file_for(dir)
  return M.dir .. "/" .. dir:gsub("/", "%%") .. ".json"
end

-- The folder nvim was started in, or nil when it was given files to open.
local function started_folder()
  local argc = vim.fn.argc()
  if argc == 0 then
    return vim.uv.fs_realpath(vim.uv.cwd())
  end
  if argc == 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
    return vim.uv.fs_realpath(vim.fn.argv(0))
  end
  return nil
end

-- Whether Claude can still find the conversation: its transcript is where it was,
-- or anywhere under ~/.claude/projects (the session may have moved folders).
local function resumable(tab)
  if not tab.session_id then
    return false
  end
  if tab.transcript_path and vim.uv.fs_stat(tab.transcript_path) then
    return true
  end
  local config = vim.env.CLAUDE_CONFIG_DIR or (vim.env.HOME .. "/.claude")
  return #vim.fn.glob(config .. "/projects/*/" .. tab.session_id .. ".jsonl", true, true) > 0
end

function M.save()
  local settings = require "floatterm.settings"
  if not folder or not settings.get "reopen_tabs" or not package.loaded.floatterm then
    return
  end

  local saved = {}
  for _, record in ipairs(require("floatterm").tabs()) do
    local tab = { kind = record.kind, cwd = record.cwd, label = record.label }
    if record.kind == "claude" then
      tab.session_id = record.session_id
      tab.transcript_path = record.transcript_path
      tab.start_ref = record.start_ref
    else
      -- An idle shell's command is the shell itself, so only a running one counts.
      local ok, tabbar = pcall(require, "floatterm.tabbar")
      local running = record.command and ok and tabbar.is_running(record)
      tab.last_command = running and record.command or record.last_command
    end
    table.insert(saved, tab)
  end

  local path = file_for(folder)
  if #saved == 0 then
    os.remove(path)
    return
  end
  vim.fn.mkdir(M.dir, "p")
  local file = io.open(path, "w")
  if file then
    file:write(vim.json.encode(saved))
    file:close()
  end
end

function M.restore()
  local settings = require "floatterm.settings"
  if done or not folder or not settings.get "reopen_tabs" then
    return
  end
  done = true

  local file = io.open(file_for(folder), "r")
  if not file then
    return
  end
  local ok, saved = pcall(vim.json.decode, file:read "*a", { luanil = { object = true } })
  file:close()
  if not ok or type(saved) ~= "table" then
    return
  end

  local floatterm = require "floatterm"
  local skipped = {}
  for _, tab in ipairs(saved) do
    local cwd = tab.cwd and vim.fn.isdirectory(tab.cwd) == 1 and tab.cwd or folder
    if tab.kind == "claude" then
      if resumable(tab) and vim.fn.isdirectory(tab.cwd or "") == 1 then
        -- Through agent so the tab gets the IDE connection and counts as its
        -- folder's Claude tab. claudecode.nvim loads lazily; it's loaded now so its
        -- port can be passed on.
        pcall(function()
          require("lazy").load { plugins = { "claudecode.nvim" } }
        end)
        require("agent").open(tab.cwd, {
          argv = { "claude", "--resume", tab.session_id },
          label = tab.label,
          session_id = tab.session_id,
          start_ref = tab.start_ref,
          show = false,
        })
      else
        table.insert(skipped, tab.label or vim.fn.fnamemodify(tab.cwd or "", ":t"))
      end
    else
      local _, buf = floatterm.new_tab(nil, { cwd = cwd, label = tab.label, show = false })
      if tab.last_command then
        floatterm.update(buf, { last_command = tab.last_command })
      end
    end
  end

  if #skipped > 0 then
    vim.notify(
      "floatterm: couldn't resume Claude in " .. table.concat(skipped, ", ") .. " (its conversation or folder is gone), so those tabs weren't reopened",
      vim.log.levels.WARN
    )
  end
end

-- Restores now (or once nvim has started) and saves on quit. Call once at startup.
function M.setup()
  folder = started_folder()
  if not folder then
    return
  end

  vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.save })
  if vim.v.vim_did_enter == 1 then
    M.restore()
  else
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = M.restore })
  end
end

return M
