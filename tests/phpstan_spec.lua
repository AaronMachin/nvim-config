-- lua/phpstan: reading PHPStan's raw output, and a run through a fake Sail.

local H = require "test_helpers"

describe("phpstan", function()
  local phpstan

  before_each(function()
    H.isolate()
    phpstan = require "phpstan"
  end)

  after_each(function()
    H.restore()
    vim.fn.setqflist({}, "r")
    pcall(vim.cmd, "cclose")
    vim.cmd "silent! %bwipeout!"
  end)

  describe("parse", function()
    it("maps container paths back to the project and keeps colons in messages", function()
      local items = phpstan.parse("/var/www/html/app/User.php:12:Call to undefined method: foo()\n", "/proj")
      assert.same({ { filename = "/proj/app/User.php", lnum = 12, text = "Call to undefined method: foo()" } }, items)
    end)

    it("opens an error with no line at the top of the file", function()
      local items = phpstan.parse("/var/www/html/app/A.php:?:Something about the file\n", "/proj")
      assert.equals(1, items[1].lnum)
    end)

    it("moves a trait's class context onto the message", function()
      local items = phpstan.parse(
        "/var/www/html/app/Concerns/HasSite.php (in context of class App\\Models\\Site):7:Bad type\n",
        "/proj"
      )
      assert.equals("/proj/app/Concerns/HasSite.php", items[1].filename)
      assert.equals("Bad type (in context of class App\\Models\\Site)", items[1].text)
    end)

    it("keeps an error that isn't about a file, without one", function()
      local items = phpstan.parse("?:?:Invalid configuration\n\n", "/proj")
      assert.same({ { text = "Invalid configuration" } }, items)
    end)
  end)

  describe("run", function()
    local project, sail

    local function run_with(script)
      H.script(project .. "/vendor/bin", "sail", script)
      H.edit(project .. "/app/A.php", { "<?php" })
      phpstan.run()
    end

    before_each(function()
      project = H.tmpdir "laravel"
      H.write(project .. "/phpstan.neon", "")
      sail = project .. "/vendor/bin/sail"
    end)

    it("puts the errors in the quickfix list", function()
      local messages = H.capture_notify()
      run_with "echo '/var/www/html/app/A.php:3:Oops'; exit 1"
      H.wait(5000, function()
        return #vim.fn.getqflist() == 1
      end)
      local item = vim.fn.getqflist()[1]
      assert.equals(project .. "/app/A.php", vim.api.nvim_buf_get_name(item.bufnr))
      assert.equals(3, item.lnum)
      assert.is_not_nil(H.notified(messages, "PHPStan: 1 error"))
      assert.is_true(H.exists(sail))
    end)

    it("says when Sail isn't running", function()
      local messages = H.capture_notify()
      run_with "echo 'Sail is not running.' >&2; exit 1"
      H.wait(5000, function()
        return H.notified(messages, "Sail isn't running") ~= nil
      end)
    end)

    it("explains a JSON summary in place of the errors", function()
      local messages = H.capture_notify()
      run_with [[echo '{"tool":"phpstan","errors":4}'; exit 1]]
      H.wait(5000, function()
        return H.notified(messages, "4 errors, but only a summary") ~= nil
      end)
    end)

    it("reports PHPStan itself falling over", function()
      local messages = H.capture_notify()
      run_with "echo 'Fatal error: memory' >&2; exit 255"
      H.wait(5000, function()
        return H.notified(messages, "PHPStan failed %(exit 255%)") ~= nil
      end)
    end)
  end)
end)
