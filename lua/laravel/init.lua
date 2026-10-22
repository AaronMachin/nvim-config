-- Telescope pickers for finding your way round a Laravel project.
--
-- routes(): the app's routes from artisan route:list, opening the controller at the
-- method a route calls. related(): the classes the method under the cursor (or the
-- whole class) uses, its tests, and for a test the class it tests.
--
-- Class names are turned into files through the project's PSR-4 map, the same way
-- Composer would load them, so nothing here needs the app to be running except
-- route:list itself.

local M = {}

local function project_root(start)
  local file = start or vim.api.nvim_buf_get_name(0)
  if file == "" then
    file = vim.uv.cwd()
  end
  return vim.fs.root(file, { "artisan" })
end

local function relative(path, root)
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

-- PSR-4 prefixes to folders, longest prefix first. Composer's generated map covers
-- vendor packages too (so a route to a package's controller still opens); composer.json
-- is the fallback when vendor isn't installed.
local psr4_cache = {}

local function psr4(root)
  if psr4_cache[root] then
    return psr4_cache[root]
  end

  local map = {}
  local ok, lines = pcall(vim.fn.readfile, root .. "/vendor/composer/autoload_psr4.php")
  if ok then
    for _, line in ipairs(lines) do
      local prefix, dirs = line:match "^%s*'(.-)'%s*=>%s*array%((.*)%),?%s*$"
      if prefix then
        prefix = prefix:gsub("\\\\", "\\")
        for base, dir in dirs:gmatch "%$(%a+)%s*%.%s*'(.-)'" do
          table.insert(map, { prefix = prefix, dir = (base == "baseDir" and root or root .. "/vendor") .. dir })
        end
      end
    end
  end

  local composer_ok, composer = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(root .. "/composer.json"), "\n"))
  end)
  if composer_ok then
    for _, section in ipairs { "autoload", "autoload-dev" } do
      for prefix, dirs in pairs((composer[section] or {})["psr-4"] or {}) do
        for _, dir in ipairs(type(dirs) == "table" and dirs or { dirs }) do
          table.insert(map, { prefix = prefix, dir = root .. "/" .. dir:gsub("/$", "") })
        end
      end
    end
  end

  table.sort(map, function(a, b)
    return #a.prefix > #b.prefix
  end)
  psr4_cache[root] = map
  return map
end

-- The file for a fully qualified class name, or nil if there isn't one.
function M.class_file(root, class)
  class = class:gsub("^\\", "")
  for _, entry in ipairs(psr4(root)) do
    if class:sub(1, #entry.prefix) == entry.prefix then
      local path = entry.dir .. "/" .. class:sub(#entry.prefix + 1):gsub("\\", "/") .. ".php"
      if vim.uv.fs_stat(path) then
        return path
      end
    end
  end
  return nil
end

-- The line `function <method>(` is on, or nil when the method isn't in the file
-- (it's inherited, say).
local function method_line(path, method)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local pattern = "function%s+&?" .. vim.pesc(method) .. "%s*%("
  for i, line in ipairs(lines) do
    if line:find(pattern) then
      return i
    end
  end
  return nil
end

-- The file and line where `class` defines `method`, following `extends` up to a few
-- parents when it's inherited. With no definition found, the class's own file and nil.
function M.method_location(root, class, method)
  local first_file = M.class_file(root, class)
  local file = first_file
  for _ = 1, 5 do
    if not file then
      break
    end
    local lnum = method_line(file, method)
    if lnum then
      return file, lnum
    end
    local ok, lines = pcall(vim.fn.readfile, file)
    if not ok then
      break
    end
    local header = M.parse_header(lines)
    local parent = header.extends and M.resolve_name(header.extends, header)
    file = parent and M.class_file(root, parent)
  end
  return first_file, nil
end

local function open_at(path, lnum)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if lnum then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd "normal! zz"
  end
end

-- Routes ------------------------------------------------------------------------

local routes_cache = {}

local function decode_routes(output)
  local start = (output or ""):find "%["
  if not start then
    return nil
  end
  -- Nulls (a route with no name) come back as nil rather than vim.NIL.
  local ok, routes = pcall(vim.json.decode, output:sub(start), { luanil = { object = true, array = true } })
  if ok and type(routes) == "table" then
    return routes
  end
  return nil
end

-- Host PHP first, as it's quicker. It fails where the app needs a service only
-- reachable inside Sail, and then Sail runs it instead.
local function load_routes(root, callback)
  vim.system({ "php", "artisan", "route:list", "--json" }, { cwd = root, text = true }, function(host)
    local routes = host.code == 0 and decode_routes(host.stdout) or nil
    if routes then
      return vim.schedule_wrap(callback)(routes)
    end
    if not vim.uv.fs_stat(root .. "/vendor/bin/sail") then
      return vim.schedule_wrap(callback)(nil, vim.trim(host.stderr ~= "" and host.stderr or host.stdout or ""))
    end
    vim.system({ "./vendor/bin/sail", "artisan", "route:list", "--json" }, { cwd = root, text = true }, function(sail)
      local sail_routes = sail.code == 0 and decode_routes(sail.stdout) or nil
      vim.schedule_wrap(callback)(sail_routes, vim.trim(sail.stderr ~= "" and sail.stderr or sail.stdout or ""))
    end)
  end)
end

-- Where a route's action lives: { class, method } for a controller, nil for a closure.
function M.parse_action(action)
  if not action or action == "Closure" then
    return nil
  end
  local class, method = action:match "^(.-)@(.+)$"
  if class then
    return { class = class, method = method }
  end
  return { class = action, method = "__invoke" }
end

local function route_entries(routes, root)
  local entries = {}
  for _, route in ipairs(routes) do
    local target = M.parse_action(route.action)
    local file, lnum
    if target then
      file, lnum = M.method_location(root, target.class, target.method)
    end
    table.insert(entries, {
      method = (route.method or ""):gsub("|HEAD$", ""),
      uri = "/" .. (route.uri or ""):gsub("^/", ""),
      name = route.name or "",
      action = route.action or "",
      target = target,
      file = file,
      lnum = lnum,
    })
  end
  return entries
end

local function show_routes(root, entries)
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local entry_display = require "telescope.pickers.entry_display"

  local method_width, uri_width = 6, 20
  for _, entry in ipairs(entries) do
    method_width = math.max(method_width, #entry.method)
    uri_width = math.max(uri_width, #entry.uri)
  end
  local displayer = entry_display.create {
    separator = "  ",
    items = { { width = method_width }, { width = math.min(uri_width, 70) }, { remaining = true } },
  }

  pickers
    .new({}, {
      prompt_title = "Routes · " .. vim.fn.fnamemodify(root, ":t"),
      results_title = #entries .. " routes · Ctrl+r reload",
      finder = finders.new_table {
        results = entries,
        entry_maker = function(route)
          return {
            value = route,
            ordinal = route.method .. " " .. route.uri .. " " .. route.name .. " " .. route.action,
            display = function()
              return displayer { { route.method, "TelescopeResultsConstant" }, route.uri, { route.name, "Comment" } }
            end,
            -- For the previewer, which shows the controller at the method.
            filename = route.file,
            lnum = route.lnum,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = conf.grep_previewer {},
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selected = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not selected then
            return
          end
          local route = selected.value
          if not route.target then
            vim.notify("laravel: " .. route.uri .. " is a closure in the routes file", vim.log.levels.WARN)
            return
          end
          if not route.file then
            vim.notify("laravel: can't find a file for " .. route.target.class, vim.log.levels.WARN)
            return
          end
          open_at(route.file, route.lnum)
          if not route.lnum then
            vim.notify("laravel: can't find where " .. route.target.method .. " is defined", vim.log.levels.WARN)
          end
        end)
        map({ "i", "n" }, "<C-r>", function()
          actions.close(prompt_bufnr)
          M.routes { refresh = true }
        end, { desc = "laravel reload routes" })
        return true
      end,
    })
    :find()
end

-- opts.refresh: run route:list again instead of using this session's copy.
function M.routes(opts)
  opts = opts or {}
  local root = project_root()
  if not root then
    vim.notify("laravel: not in a Laravel project (no artisan)", vim.log.levels.WARN)
    return
  end

  if routes_cache[root] and not opts.refresh then
    show_routes(root, routes_cache[root])
    return
  end

  vim.notify "laravel: loading routes"
  load_routes(root, function(routes, reason)
    if not routes then
      vim.notify("laravel: route:list failed: " .. (reason or ""):sub(1, 500), vim.log.levels.ERROR)
      return
    end
    routes_cache[root] = route_entries(routes, root)
    if opts.on_loaded then
      opts.on_loaded(routes_cache[root])
      return
    end
    show_routes(root, routes_cache[root])
  end)
end

-- Related files -----------------------------------------------------------------

-- The namespace, the short names `use` brings in, and the class declared, from a
-- PHP file's lines.
function M.parse_header(lines)
  local header = { namespace = nil, uses = {}, class = nil }
  for _, line in ipairs(lines) do
    header.namespace = header.namespace or line:match "^%s*namespace%s+([%w_\\]+)%s*;"

    local group_prefix, group = line:match "^%s*use%s+([%w_\\]+)\\{(.-)}%s*;"
    if group_prefix then
      for item in group:gmatch "[^,]+" do
        local name, alias = vim.trim(item):match "^([%w_\\]+)%s+as%s+([%w_]+)$"
        name = name or vim.trim(item)
        header.uses[alias or name:match "([%w_]+)$"] = group_prefix .. "\\" .. name
      end
    else
      local name, alias = line:match "^%s*use%s+([%w_\\]+)%s+as%s+([%w_]+)%s*;"
      name = name or line:match "^%s*use%s+([%w_\\]+)%s*;"
      if name and not line:match "^%s*use%s+function%s" then
        header.uses[alias or name:match "([%w_]+)$"] = name
      end
    end

    header.extends = header.extends or line:match "^%s*[%w%s]-class%s+[%w_]+%s+extends%s+([%w_\\]+)"
    header.class = header.class
      or line:match "^%s*[%w%s]-class%s+([%w_]+)"
      or line:match "^%s*interface%s+([%w_]+)"
      or line:match "^%s*trait%s+([%w_]+)"
      or line:match "^%s*enum%s+([%w_]+)"
  end
  return header
end

-- What a related file is, for the picker's first column.
function M.kind(path, root)
  local rel = relative(path, root)
  local name = vim.fn.fnamemodify(path, ":t:r")
  if rel:match "^tests/" then
    return "test"
  end
  if name:match "Request$" or rel:match "/Requests/" then
    return "request"
  end
  if name:match "Resource$" or rel:match "/Resources/" then
    return "resource"
  end
  if rel:match "^app/Models/" then
    return "model"
  end
  if name:match "Controller$" then
    return "controller"
  end
  return "class"
end

-- The lines to look for class names in: the method around the cursor with its
-- docblock (so @param and @return types count), else the whole class.
local function scope_lines(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
  if not ok or not node then
    return lines, nil
  end

  while node and node:type() ~= "method_declaration" and node:type() ~= "function_definition" do
    node = node:parent()
  end
  if not node then
    return lines, nil
  end

  local first, _, last = node:range()
  local previous = node:prev_named_sibling()
  if previous and previous:type() == "comment" then
    first = previous:range()
  end
  local name_node = node:field("name")[1]
  local name = name_node and vim.treesitter.get_node_text(name_node, bufnr) or nil
  return vim.list_slice(lines, first + 1, last + 1), name
end

-- The fully qualified name a class name in a file stands for: through its `use`
-- statements, else in the file's own namespace. A leading \ means it's already full.
function M.resolve_name(name, header)
  if name:sub(1, 1) == "\\" then
    return name:sub(2)
  end
  local first, rest = name:match "^([%w_]+)(.*)$"
  if header.uses[first] then
    return header.uses[first] .. rest
  end
  if header.namespace then
    return header.namespace .. "\\" .. name
  end
  return name
end

-- Leaves out PHP's own types and keywords that look like class names.
local NOT_CLASSES = {
  ["self"] = true,
  ["static"] = true,
  ["parent"] = true,
  ["TRUE"] = true,
  ["FALSE"] = true,
  ["NULL"] = true,
}

-- The files of the classes named in `lines`, each once, through `use` statements,
-- fully qualified names and the file's own namespace.
function M.referenced_files(lines, header, root)
  local seen, files = {}, {}
  local text = table.concat(lines, "\n")
  -- Strings are skipped so a message mentioning a word doesn't count. Docblocks are
  -- kept, as they hold the generic types (Collection<int, User>).
  text = text:gsub("'[^'\n]*'", "''"):gsub('"[^"\n]*"', '""')

  for name in text:gmatch "%f[%w_\\$]\\?%u[%w_\\]*" do
    if not NOT_CLASSES[name] then
      local class = M.resolve_name(name, header)
      if not seen[class] then
        seen[class] = true
        local file = M.class_file(root, class)
        if file then
          table.insert(files, file)
        end
      end
    end
  end
  return files
end

local function find_files(names, path)
  if not vim.uv.fs_stat(path) then
    return {}
  end
  return vim.fs.find(names, { path = path, type = "file", limit = math.huge })
end

-- Everything related to the PHP class in `bufnr`, as { path, kind } rows.
function M.related_files(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = project_root(file)
  if not root or not file:match "%.php$" then
    return nil, "not a PHP file in a Laravel project"
  end

  local header = M.parse_header(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  -- Pest tests have no class, so the file's name stands in for one.
  header.class = header.class or vim.fn.fnamemodify(file, ":t:r")

  local rows, seen = {}, { [file] = true }
  local function add(path, kind)
    path = vim.fs.normalize(path)
    if not seen[path] then
      seen[path] = true
      table.insert(rows, { path = path, kind = kind or M.kind(path, root) })
    end
  end

  local lines, method = scope_lines(bufnr)
  for _, path in ipairs(M.referenced_files(lines, header, root)) do
    add(path)
  end

  for _, path in ipairs(find_files({ header.class .. "Test.php" }, root .. "/tests")) do
    add(path, "test")
  end

  -- A test is named after what it tests, so FooTest leads back to Foo.
  local tested = header.class:match "^(.+)Test$"
  if tested then
    for _, folder in ipairs { "app", "database" } do
      for _, path in ipairs(find_files({ tested .. ".php" }, root .. "/" .. folder)) do
        add(path)
      end
    end
  end

  -- The project's own files first, then vendor's, each in the order found.
  for i, row in ipairs(rows) do
    row.order = (relative(row.path, root):match "^vendor/" and 1000 or 0) + i
  end
  table.sort(rows, function(a, b)
    return a.order < b.order
  end)

  return rows, nil, { root = root, class = header.class, method = method }
end

function M.related()
  local rows, reason, info = M.related_files(0)
  if not rows then
    vim.notify("laravel: " .. reason, vim.log.levels.WARN)
    return
  end
  if #rows == 0 then
    vim.notify("laravel: nothing related found for " .. info.class, vim.log.levels.INFO)
    return
  end

  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local entry_display = require "telescope.pickers.entry_display"

  local displayer = entry_display.create {
    separator = "  ",
    items = { { width = 10 }, { width = 36 }, { remaining = true } },
  }

  pickers
    .new({}, {
      prompt_title = "Related · " .. info.class .. (info.method and ("::" .. info.method) or ""),
      finder = finders.new_table {
        results = rows,
        entry_maker = function(row)
          local name = vim.fn.fnamemodify(row.path, ":t:r")
          local rel = relative(row.path, info.root)
          return {
            value = row,
            ordinal = row.kind .. " " .. name .. " " .. rel,
            display = function()
              return displayer { { row.kind, "TelescopeResultsConstant" }, name, { rel, "Comment" } }
            end,
            path = row.path,
            filename = row.path,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = conf.file_previewer {},
    })
    :find()
end

return M
