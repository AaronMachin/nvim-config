-- Live grep with IntelliJ-style file masks and search options.
--
-- A mask is a comma-separated list of wildcards ("*.php, !*Test.php, !vendor/**"),
-- passed to ripgrep as --glob. Each project (git root, else cwd) remembers its own
-- active mask, and every mask used goes into a recent list shared by all projects.
-- Both are kept in stdpath("data")/grepmask.json so they survive restarts.
--
-- Ctrl+f switches the prompt between the search text and the mask. Results follow
-- either as you type, and while the mask is being edited the recent masks list sits
-- over the preview, where Up/Down tries each one.

local M = {}

local MAX_RECENT = 20
-- A field rather than a local so tests can point it somewhere other than the live file.
M.state_path = vim.fn.stdpath "data" .. "/grepmask.json"

-- Left out of every search unless turned off for the picker with Ctrl+Shift+d. A mask
-- entry naming one of these (say "*.svg") still wins, as later globs take precedence.
M.default_excludes = {
  "!*.lock",
  "!*-lock.yaml",
  "!*-lock.json",
  "!*.svg",
  "!*.min.*",
  "!*.map",
  "!**/generated/**",
  "!*.generated.*",
  "!frontend/design-system/**",
}

-- Like IntelliJ's Find in Files toggles, these last until nvim restarts. Regex is
-- off, so what you type is searched for as written.
local toggles = { case = false, word = false, regex = false }

local HINTS = "C-f mask · C-S-c case · C-S-w word · C-S-r regex · C-S-d defaults · C-↑/↓ history"

local function read_state()
  local state = { recent = {}, active = {} }
  local file = io.open(M.state_path, "r")
  if not file then
    return state
  end

  local ok, decoded = pcall(vim.json.decode, file:read "*a")
  file:close()
  if ok and type(decoded) == "table" then
    state.recent = type(decoded.recent) == "table" and decoded.recent or {}
    state.active = type(decoded.active) == "table" and decoded.active or {}
  end

  return state
end

local function write_state(state)
  local file = io.open(M.state_path, "w")
  if not file then
    vim.notify("grepmask: could not write " .. M.state_path, vim.log.levels.WARN)
    return
  end

  -- An empty `active` table would encode as [], which is fine to read back.
  file:write(vim.json.encode(state))
  file:close()
end

local function project_root()
  local cwd = vim.uv.cwd()
  return vim.fs.root(cwd, ".git") or cwd
end

local function parse_mask(mask)
  local globs = {}
  for entry in (mask or ""):gmatch "[^,]+" do
    entry = vim.trim(entry)
    if entry ~= "" then
      table.insert(globs, entry)
    end
  end
  return globs
end

function M.active_mask()
  return read_state().active[project_root()]
end

function M.set_mask(mask)
  local state = read_state()
  local root = project_root()
  mask = table.concat(parse_mask(mask), ", ")

  if mask == "" then
    state.active[root] = nil
    write_state(state)
    return
  end

  state.active[root] = mask
  state.recent = vim.tbl_filter(function(recent)
    return recent ~= mask
  end, state.recent)
  table.insert(state.recent, 1, mask)
  while #state.recent > MAX_RECENT do
    table.remove(state.recent)
  end

  write_state(state)
end

-- The ripgrep command for a search, or nil when there's nothing to search for.
function M.build_command(query, mask, options, use_defaults)
  if query == "" then
    return nil
  end

  local args = vim.deepcopy(require("telescope.config").values.vimgrep_arguments)
  -- Each of these comes after telescope's --smart-case, so it wins.
  if options.case then
    table.insert(args, "--case-sensitive")
  end
  if options.word then
    table.insert(args, "--word-regexp")
  end
  if not options.regex then
    table.insert(args, "--fixed-strings")
  end
  if use_defaults then
    for _, glob in ipairs(M.default_excludes) do
      table.insert(args, "--glob=" .. glob)
    end
  end
  for _, glob in ipairs(parse_mask(mask)) do
    table.insert(args, "--glob=" .. glob)
  end

  vim.list_extend(args, { "--", query })
  return args
end

local function title(session)
  local parts = { session.editing == "mask" and ("Mask · searching: " .. session.query) or "Live Grep" }
  if session.editing == "search" and session.mask ~= "" then
    table.insert(parts, "[" .. session.mask .. "]")
  end
  if session.options.case then
    table.insert(parts, "[Cc]")
  end
  if session.options.word then
    table.insert(parts, "[W]")
  end
  if session.options.regex then
    table.insert(parts, "[.*]")
  end
  -- Shown while files are being left out, so an empty search doesn't look conclusive.
  if session.use_defaults then
    table.insert(parts, "[default excludes]")
  end
  return table.concat(parts, " ")
end

-- The recent masks list, drawn over the preview pane (or the results, if the preview
-- is hidden) while the mask is being edited.
local function draw_recent(session, picker)
  local layout = picker.layout
  local anchor = (layout.preview and layout.preview.winid) or layout.results.winid
  if not (anchor and vim.api.nvim_win_is_valid(anchor)) then
    return
  end

  local lines = { " Recent masks: ↑/↓ to try one, Enter or C-f to keep it", "" }
  local selected_line = nil
  if #session.recent == 0 then
    table.insert(lines, "   None yet. A mask you keep is added here.")
  end
  for i, mask in ipairs(session.recent) do
    table.insert(lines, string.format(" %s %2d  %s", i == session.recent_index and "▶" or " ", i, mask))
    if i == session.recent_index then
      selected_line = #lines - 1
    end
  end

  if not (session.recent_buf and vim.api.nvim_buf_is_valid(session.recent_buf)) then
    session.recent_buf = vim.api.nvim_create_buf(false, true)
  end
  vim.api.nvim_buf_set_lines(session.recent_buf, 0, -1, false, lines)
  local namespace = vim.api.nvim_create_namespace "grepmask"
  vim.api.nvim_buf_clear_namespace(session.recent_buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(session.recent_buf, namespace, "Comment", 0, 0, -1)
  if selected_line then
    vim.api.nvim_buf_add_highlight(session.recent_buf, namespace, "TelescopeSelection", selected_line, 0, -1)
  end

  if session.recent_win and vim.api.nvim_win_is_valid(session.recent_win) then
    return
  end
  session.recent_win = vim.api.nvim_open_win(session.recent_buf, false, {
    relative = "win",
    win = anchor,
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(anchor),
    height = vim.api.nvim_win_get_height(anchor),
    style = "minimal",
    focusable = false,
    zindex = 200,
    noautocmd = true,
  })
  vim.wo[session.recent_win].winhighlight = "Normal:TelescopePreviewNormal"
end

local function close_recent(session)
  if session.recent_win and vim.api.nvim_win_is_valid(session.recent_win) then
    vim.api.nvim_win_close(session.recent_win, true)
  end
  session.recent_win = nil
end

-- Re-runs the search with the prompt as it is, after an option changes.
local function rerun(session, picker)
  picker.layout.prompt.border:change_title(title(session))
  picker:set_prompt(require("telescope.actions.state").get_current_line())
end

local function edit_mask(session, picker)
  session.query = require("telescope.actions.state").get_current_line()
  session.editing = "mask"
  session.recent = read_state().recent
  session.recent_index = 0
  session.typed_mask = session.mask

  picker:change_prompt_prefix " mask: "
  picker.layout.prompt.border:change_title(title(session))
  picker:set_prompt(session.mask)
  draw_recent(session, picker)
end

local function keep_mask(session, picker)
  session.mask = table.concat(parse_mask(require("telescope.actions.state").get_current_line()), ", ")
  M.set_mask(session.mask)
  session.editing = "search"

  close_recent(session)
  picker:change_prompt_prefix(session.search_prefix)
  picker.layout.prompt.border:change_title(title(session))
  picker:set_prompt(session.query)
end

-- Steps through the recent masks (0 is what was typed), putting each in the prompt
-- so the results show what it does.
local function try_recent(session, picker, step)
  if session.recent_index == 0 then
    session.typed_mask = require("telescope.actions.state").get_current_line()
  end
  session.recent_index = (session.recent_index + step) % (#session.recent + 1)

  picker:set_prompt(session.recent_index == 0 and session.typed_mask or session.recent[session.recent_index])
  draw_recent(session, picker)
end

-- opts.default_text: text to search for straight away.
-- opts.word: search for it as a whole word in this picker only.
function M.live_grep(opts)
  opts = opts or {}
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local make_entry = require "telescope.make_entry"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"

  local session = {
    editing = "search",
    query = opts.default_text or "",
    mask = M.active_mask() or "",
    options = vim.tbl_extend("force", toggles, opts.word and { word = true } or {}),
    use_defaults = true,
    recent = {},
    recent_index = 0,
  }
  local picker_opts = { cwd = vim.uv.cwd() }

  local finder = finders.new_job(function(prompt)
    if session.editing == "mask" then
      return M.build_command(session.query, prompt, session.options, session.use_defaults)
    end
    return M.build_command(prompt, session.mask, session.options, session.use_defaults)
  end, make_entry.gen_from_vimgrep(picker_opts), nil, picker_opts.cwd)

  local picker = pickers.new(picker_opts, {
    prompt_title = title(session),
    preview_title = HINTS,
    default_text = session.query,
    finder = finder,
    previewer = conf.grep_previewer(picker_opts),
    sorter = require("telescope.sorters").highlighter_only(picker_opts),
    push_cursor_on_edit = true,
    attach_mappings = function(prompt_bufnr, map)
      local picker = action_state.get_current_picker(prompt_bufnr)
      session.search_prefix = picker.prompt_prefix

      local function both(lhs, fn, desc)
        map({ "i", "n" }, lhs, fn, { desc = desc })
      end

      both("<C-f>", function()
        if session.editing == "mask" then
          keep_mask(session, picker)
        else
          edit_mask(session, picker)
        end
      end, "grepmask edit or keep the file mask")
      both("<CR>", function()
        if session.editing == "mask" then
          keep_mask(session, picker)
        else
          actions.select_default(prompt_bufnr)
        end
      end, "grepmask open match, or keep the file mask")
      both("<Up>", function()
        if session.editing == "mask" then
          try_recent(session, picker, -1)
        else
          actions.move_selection_previous(prompt_bufnr)
        end
      end, "grepmask previous match or recent mask")
      both("<Down>", function()
        if session.editing == "mask" then
          try_recent(session, picker, 1)
        else
          actions.move_selection_next(prompt_bufnr)
        end
      end, "grepmask next match or recent mask")
      -- Stock live grep has this; a picker of our own has to add it back.
      both("<C-Space>", actions.to_fuzzy_refine, "grepmask filter the current results")
      both("<C-Up>", actions.cycle_history_prev, "grepmask previous search")
      both("<C-Down>", actions.cycle_history_next, "grepmask next search")

      for lhs, option in pairs { ["<C-S-c>"] = "case", ["<C-S-w>"] = "word", ["<C-S-r>"] = "regex" } do
        both(lhs, function()
          session.options[option] = not session.options[option]
          toggles[option] = session.options[option]
          rerun(session, picker)
        end, "grepmask toggle " .. option)
      end
      both("<C-S-d>", function()
        session.use_defaults = not session.use_defaults
        rerun(session, picker)
      end, "grepmask toggle default excludes")

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = function()
          close_recent(session)
        end,
      })
      return true
    end,
  })

  picker:find()
end

-- Greps the word under the cursor as a whole word, or in visual mode the selected
-- text (its first line) as written.
function M.grep_word()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd 'noautocmd normal! "zy'
    local text = vim.split(vim.fn.getreg "z", "\n")[1]
    M.live_grep { default_text = text }
  else
    M.live_grep { default_text = vim.fn.expand "<cword>", word = true }
  end
end

return M
