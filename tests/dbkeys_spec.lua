-- lua/dbkeys: reading a Laravel .env and building the database URL.

local H = require "test_helpers"

describe("dbkeys", function()
  local dbkeys

  before_each(function()
    H.isolate()
    dbkeys = require "dbkeys"
  end)

  it("reads .env values: quotes, comments, export and empty values", function()
    local path = H.write(H.tmpdir "env" .. "/.env", table.concat({
      "# a comment",
      "APP_NAME=Laravel",
      "DB_CONNECTION=pgsql # after the value",
      'DB_PASSWORD="s3cret # not a comment"',
      "DB_USERNAME='sail' # quoted, then a comment",
      "export FORWARD_DB_PORT=5433",
      "DB_HOST=",
      "  SPACED  =  value  ",
      "NOT A LINE",
    }, "\n"))
    local env = dbkeys.read_env(path)
    assert.equals("Laravel", env.APP_NAME)
    assert.equals("pgsql", env.DB_CONNECTION)
    assert.equals("s3cret # not a comment", env.DB_PASSWORD)
    assert.equals("sail", env.DB_USERNAME)
    assert.equals("5433", env.FORWARD_DB_PORT)
    assert.equals("", env.DB_HOST)
    assert.equals("value", env.SPACED)
  end)

  it("gives nil for a missing file", function()
    assert.is_nil(dbkeys.read_env "/no/such/.env")
  end)

  it("connects to the port Sail forwards, with the credentials encoded", function()
    local url = dbkeys.build_url({
      DB_CONNECTION = "pgsql",
      DB_HOST = "pgsql",
      DB_USERNAME = "sail",
      DB_PASSWORD = "p@ss/word",
      DB_DATABASE = "app",
      FORWARD_DB_PORT = "5433",
    }, "/proj")
    assert.equals("postgresql://sail:p%40ss%2Fword@127.0.0.1:5433/app", url)
    assert.equals("mysql://127.0.0.1:3306/app", dbkeys.build_url({ DB_CONNECTION = "mysql", DB_DATABASE = "app" }, "/p"))
    assert.equals(
      "mysql://root@127.0.0.1:3306/app",
      dbkeys.build_url({ DB_CONNECTION = "mariadb", DB_USERNAME = "root", DB_DATABASE = "app" }, "/p")
    )
  end)

  it("finds a SQLite file from the project, and says when it's missing", function()
    local project = H.tmpdir "proj"
    local url, reason = dbkeys.build_url({ DB_CONNECTION = "sqlite" }, project)
    assert.is_nil(url)
    assert.truthy(reason:find("database/database.sqlite doesn't exist", 1, true))
    H.write(project .. "/database/database.sqlite", "")
    assert.equals("sqlite:" .. project .. "/database/database.sqlite", dbkeys.build_url({ DB_CONNECTION = "sqlite" }, project))
    assert.equals("sqlite::memory:", dbkeys.build_url({ DB_CONNECTION = "sqlite", DB_DATABASE = ":memory:" }, project))
  end)

  it("explains a connection it can't build", function()
    local _, reason = dbkeys.build_url({}, "/p")
    assert.equals(".env has no DB_CONNECTION", reason)
    _, reason = dbkeys.build_url({ DB_CONNECTION = "sqlsrv" }, "/p")
    assert.truthy(reason:find("isn't supported", 1, true))
  end)
end)
