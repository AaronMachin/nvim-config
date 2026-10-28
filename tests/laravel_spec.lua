-- lua/laravel: routes resolved to the controller method they call (through PSR-4,
-- following `extends`), on the fixture in tests/fixtures/laravel with a fake `php`.

local H = require "test_helpers"

describe("laravel", function()
  local laravel, project

  before_each(function()
    local paths = H.isolate()
    laravel = require "laravel"
    -- A copy, so nothing is ever written into the config's own folder.
    project = paths.dir .. "/app"
    vim.fn.system { "cp", "-R", H.config .. "/tests/fixtures/laravel", project }
    vim.cmd.cd(project)
  end)

  after_each(function()
    H.restore()
    vim.cmd "silent! %bwipeout!"
  end)

  it("reads an action as class and method, an invokable as __invoke, a closure as nothing", function()
    assert.same({ class = "App\\A", method = "index" }, laravel.parse_action "App\\A@index")
    assert.same({ class = "App\\B", method = "__invoke" }, laravel.parse_action "App\\B")
    assert.is_nil(laravel.parse_action "Closure")
  end)

  it("finds a method in the class, or up its parents", function()
    local file, lnum = laravel.method_location(project, "App\\Http\\Controllers\\UserController", "store")
    assert.equals(project .. "/app/Http/Controllers/UserController.php", file)
    assert.equals(15, lnum)
    file, lnum = laravel.method_location(project, "App\\Http\\Controllers\\UserController", "show")
    assert.equals(project .. "/app/Http/Controllers/Controller.php", file)
    assert.equals(7, lnum)
    -- Not anywhere: the class's own file, no line.
    file, lnum = laravel.method_location(project, "App\\Http\\Controllers\\UserController", "nope")
    assert.equals(project .. "/app/Http/Controllers/UserController.php", file)
    assert.is_nil(lnum)
  end)

  it("resolves every route from route:list to a file and line", function()
    local bin = H.fake_bin()
    -- route:list with a PHP warning before the JSON, as a real app sometimes prints.
    H.script(bin, "php", ('echo "Deprecated: something"; cat %q'):format(project .. "/routes.json"))
    local entries
    laravel.routes {
      refresh = true,
      on_loaded = function(e)
        entries = e
      end,
    }
    H.wait(5000, function()
      return entries ~= nil
    end)
    local by_uri = {}
    for _, entry in ipairs(entries) do
      by_uri[entry.method .. " " .. entry.uri] = entry
    end
    local index = by_uri["GET /users"]
    assert.equals("users.index", index.name)
    assert.equals(project .. "/app/Http/Controllers/UserController.php", index.file)
    assert.equals(10, index.lnum)
    assert.equals(project .. "/app/Http/Controllers/Controller.php", by_uri["GET /users/{user}"].file)
    assert.equals("", by_uri["GET /users/{user}"].name)
    assert.equals(7, by_uri["GET /up"].lnum)
    assert.equals(project .. "/vendor/acme/pkg/src/PingController.php", by_uri["GET /ping"].file)
    assert.is_nil(by_uri["GET /"].target)
    assert.is_nil(by_uri["GET /gone"].file)
  end)

  it("reports route:list failing", function()
    local bin = H.fake_bin()
    H.script(bin, "php", "echo 'Could not connect to the database' >&2; exit 1")
    local messages = H.capture_notify()
    laravel.routes { refresh = true, on_loaded = function() end }
    H.wait(5000, function()
      return H.notified(messages, "route:list failed: Could not connect") ~= nil
    end)
  end)

  it("finds the related files of a controller and its test", function()
    H.edit(project .. "/app/Http/Controllers/UserController.php")
    local rows = laravel.related_files(0)
    local kinds = {}
    for _, row in ipairs(rows) do
      kinds[vim.fn.fnamemodify(row.path, ":t")] = row.kind
    end
    assert.equals("model", kinds["User.php"])
    assert.equals("controller", kinds["Controller.php"])
    assert.equals("test", kinds["UserControllerTest.php"])

    H.edit(project .. "/tests/Feature/UserControllerTest.php")
    rows = laravel.related_files(0)
    assert.equals(project .. "/app/Http/Controllers/UserController.php", rows[1].path)
  end)
end)
