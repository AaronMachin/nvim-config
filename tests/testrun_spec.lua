-- lua/testrun: the nearest Pest test and the command it runs (in a floatterm tab,
-- stubbed here).

local H = require "test_helpers"

local testrun, ran

local TEST = {
  "<?php",
  "",
  "it('logs in (with email)', function () {",
  "    expect(true)->toBeTrue();",
  "});",
  "",
  'test("rejects a bad password", function () {',
  "    expect(false)->toBeFalse();",
  "});",
}

describe("testrun", function()
  local project

  before_each(function()
    local paths = H.isolate()
    project = paths.start .. "/app"
    H.write(project .. "/artisan", "")
    testrun = require "testrun"
    ran = {}
    H.stub(require "floatterm", "run_in_tab", function(command)
      table.insert(ran, command)
      return 1, -1
    end)
  end)

  after_each(function()
    H.restore()
    vim.cmd "silent! %bwipeout!"
  end)

  it("runs the it() at or above the cursor, its punctuation escaped for --filter", function()
    H.edit(project .. "/tests/Feature/LoginTest.php", TEST)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    testrun.run "nearest"
    assert.equals(
      "cd " .. vim.fn.shellescape(project) .. " && php artisan test --compact 'tests/Feature/LoginTest.php' --filter='logs in \\(with email\\)'",
      ran[1]
    )
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    testrun.run "nearest"
    assert.truthy(ran[2]:find("--filter='rejects a bad password'", 1, true))
  end)

  it("runs the whole file, through Sail when the project has it", function()
    H.write(project .. "/vendor/bin/sail", "")
    H.edit(project .. "/tests/Feature/LoginTest.php", TEST)
    testrun.run "file"
    local expected = "&& ./vendor/bin/sail artisan test --compact 'tests/Feature/LoginTest.php'"
    assert.equals(expected, ran[1]:sub(-#expected))
  end)

  it("runs the last command again", function()
    H.edit(project .. "/tests/Feature/LoginTest.php", TEST)
    testrun.run "file"
    vim.cmd "enew"
    testrun.run_last()
    assert.equals(ran[1], ran[2])
    assert.equals(ran[1]:gsub("^cd .- && ", ""), testrun.last_command())
  end)

  it("refuses a file that isn't a test, or no test above the cursor", function()
    local messages = H.capture_notify()
    H.edit(project .. "/app/User.php", { "<?php" })
    testrun.run "file"
    assert.is_not_nil(H.notified(messages, "not a Pest test file"))
    H.edit(project .. "/tests/Unit/EmptyTest.php", { "<?php", "" })
    testrun.run "nearest"
    assert.is_not_nil(H.notified(messages, "no it%(%) or test%(%)"))
    assert.equals(0, #ran)
  end)

  it("reads back the last run's output", function()
    local real = package.loaded["floatterm"]
    H.restore()
    H.isolate()
    H.write(project .. "/artisan", "")
    H.edit(project .. "/tests/Feature/LoginTest.php", TEST)
    -- A tab that prints and stays open, standing in for the test run.
    H.stub(real, "run_in_tab", function(_, opts)
      return real.new_tab({ "sh", "-c", "echo PASS; sleep 300" }, opts)
    end)
    testrun.run "file"
    H.wait(3000, function()
      local out = testrun.last_output()
      return out and out[#out] == "PASS"
    end)
    H.close_all_tabs()
    H.wait(2000, function()
      return testrun.last_output() == nil
    end)
  end)
end)
