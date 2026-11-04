-- lua/localenv (settings for this machine from the config's .env).

local H = require "test_helpers"

describe("localenv", function()
  local localenv, path

  before_each(function()
    local case = H.isolate()
    localenv = require "localenv"
    path = case.dir .. "/.env"
    H.stub(vim.env, "LOCALENV_TEST_A", nil)
    H.stub(vim.env, "LOCALENV_TEST_B", nil)
  end)

  after_each(function()
    H.restore()
  end)

  it("sets what .env holds, quoted or not, skipping comments and empty values", function()
    H.write(path, '# a comment\nLOCALENV_TEST_A="https://x.atlassian.net"\nLOCALENV_TEST_B=\n')
    localenv.load(path)
    assert.equals("https://x.atlassian.net", vim.env.LOCALENV_TEST_A)
    assert.is_nil(vim.env.LOCALENV_TEST_B)
  end)

  it("leaves a variable the shell already set", function()
    vim.env.LOCALENV_TEST_A = "from the shell"
    H.write(path, "LOCALENV_TEST_A=from .env\n")
    localenv.load(path)
    assert.equals("from the shell", vim.env.LOCALENV_TEST_A)
  end)

  it("does nothing without a .env", function()
    localenv.load(path .. ".missing")
    assert.is_nil(vim.env.LOCALENV_TEST_A)
  end)
end)
