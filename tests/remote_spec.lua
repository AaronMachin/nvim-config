-- lua/floatterm/remote, bin/floatterm-offer and bin/floatterm-tab: files offered in a
-- pop-up, and tabs opened from a tab.

local H = require "test_helpers"

local api = vim.api
local ft, remote, groups

local function press(text)
  api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "x", false)
end

-- The pop-up's lines, or nil when it isn't showing.
local function popup_lines()
  for _, win in ipairs(api.nvim_list_wins()) do
    local config = api.nvim_win_get_config(win)
    if config.relative ~= "" and config.title and vim.inspect(config.title):find("wants you to look at", 1, true) then
      return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), win
    end
  end
  return nil
end

local function settle()
  H.flush(50)
end

-- Runs a script from bin/ as Claude in the tab `buf` would, answering its calls to
-- this nvim while it waits. `during` runs once it's started.
local function run(script, args, buf, during)
  local started = vim.v.servername == "" and vim.fn.serverstart "127.0.0.1:0" or nil
  local env = { NVIM = started or vim.v.servername, FLOATTERM_TAB_ID = buf and tostring(ft.record(buf).id) or "" }
  local done
  vim.system(vim.list_extend({ H.config .. "/bin/" .. script }, args), { text = true, env = env }, function(result)
    done = result
  end)
  if during then
    during()
  end
  H.wait(15000, function()
    return done ~= nil
  end, script .. " didn't finish")
  if started then
    vim.fn.serverstop(started)
  end
  return done
end

describe("floatterm remote", function()
  local file

  before_each(function()
    H.isolate()
    ft = require "floatterm"
    remote = require "floatterm.remote"
    groups = require "floatterm.groups"
    require("floatterm.tabbar").setup()
    H.isolate()
    H.stub(remote, "ARM_MS", 0)
    file = H.write(H.tmpdir "offer" .. "/plan.md", "# Plan\n\nDo the thing\n")
  end)

  after_each(function()
    pcall(vim.cmd, "silent! tabonly!")
    H.close_all_tabs()
    H.restore()
    H.close_floats()
    pcall(vim.cmd, "stopinsert")
  end)

  describe("offering a file", function()
    it("shows the pop-up straight away on the tab you're in, and Preview shows it read-only", function()
      local buf = H.sleep_tab { label = "api" }
      api.nvim_set_current_win(ft.window())
      local id = remote.offer(ft.record(buf).id, file)
      assert.truthy(id ~= "")
      settle()
      local lines = popup_lines()
      assert.truthy(lines, "no pop-up")
      assert.equals(" plan.md", lines[1])
      for _, choice in ipairs { "o  Open in nvim", "p  Preview here", "y  Copy full path", "n  Don't open" } do
        assert.truthy(vim.tbl_contains(lines, "  " .. choice), choice)
      end
      press "p"
      assert.equals("previewed", remote.result(id))
      assert.truthy(vim.tbl_contains(api.nvim_buf_get_lines(0, 0, -1, false), "Do the thing"))
      assert.is_false(vim.bo.modifiable)
      press "q"
      assert.equals(ft.window(), api.nvim_get_current_win())
    end)

    it("waits for you to go to the offering tab, with 📄 in the bar until then", function()
      local asking = H.sleep_tab { label = "asking" }
      local other = H.sleep_tab { label = "other" }
      api.nvim_set_current_win(ft.window())
      local id = remote.offer(ft.record(asking).id, file)
      settle()
      assert.is_nil(popup_lines())
      require("floatterm.tabbar").redraw()
      assert.truthy(table.concat(require("floatterm.tabbar").lines(), "\n"):find("📄", 1, true))
      ft.focus_buf(asking)
      api.nvim_set_current_win(ft.window())
      settle()
      assert.truthy(popup_lines(), "no pop-up on arriving")
      press "n"
      assert.equals("not opened", remote.result(id))
      assert.is_nil(popup_lines())
      assert.same({}, remote.waiting(ft.record(asking)))
      assert.is_not_nil(other)
    end)

    it("copies the full path with y", function()
      local buf = H.sleep_tab { label = "api" }
      api.nvim_set_current_win(ft.window())
      local id = remote.offer(ft.record(buf).id, file)
      settle()
      H.capture_notify()
      press "y"
      assert.equals("copied", remote.result(id))
      assert.equals(vim.fn.fnamemodify(file, ":p"), vim.fn.getreg "+")
    end)

    it("opens it in a new nvim tab with o, hiding the float", function()
      local buf = H.sleep_tab { label = "api" }
      api.nvim_set_current_win(ft.window())
      local id = remote.offer(ft.record(buf).id, file)
      settle()
      press "o"
      assert.equals("opened", remote.result(id))
      assert.equals(vim.fn.resolve(vim.fn.fnamemodify(file, ":p")), vim.fn.resolve(vim.fn.expand "%:p"))
      assert.is_false(ft.layout().open)
    end)

    it("shows several one after another, and ignores keys pressed as it appears", function()
      H.stub(remote, "ARM_MS", 300)
      local buf = H.sleep_tab { label = "api" }
      api.nvim_set_current_win(ft.window())
      local second = H.write(H.tmpdir "offer2" .. "/notes.md", "x\n")
      local first_id = remote.offer(ft.record(buf).id, file)
      local second_id = remote.offer(ft.record(buf).id, second)
      settle()
      press "n"
      assert.equals("", remote.result(first_id))
      H.flush(350)
      press "n"
      assert.equals("not opened", remote.result(first_id))
      settle()
      local lines = popup_lines()
      assert.truthy(lines, "no second pop-up")
      assert.equals(" notes.md", lines[1])
      H.flush(350)
      press "n"
      assert.equals("not opened", remote.result(second_id))
    end)

    it("refuses a missing file or a tab that isn't there", function()
      local buf = H.sleep_tab { label = "api" }
      assert.equals("", remote.offer(ft.record(buf).id, "/no/such/file"))
      assert.equals("", remote.offer(99999, file))
    end)
  end)

  describe("opening a tab", function()
    it("opens a Claude tab under the asking tab, with its prompt and label, leaving you where you are", function()
      local asking = H.sleep_tab { label = "lead" }
      local started
      H.stub(require "agent", "open", function(dir, opts)
        started = { dir = dir, opts = opts }
        local _, buf = ft.new_tab({ "sleep", "300" }, { cwd = dir, label = opts.label, kind = "claude", show = false })
        return buf
      end)
      local id = remote.open_tab(ft.record(asking).id, vim.json.encode { under = true, claude = "Do task 3", label = "task 3" })
      assert.truthy(id ~= "")
      assert.same({ "claude", "Do task 3" }, started.opts.argv)
      assert.equals("task 3", started.opts.label)
      assert.is_false(started.opts.show)
      local child
      for _, record in ipairs(ft.tabs()) do
        if tostring(record.id) == id then
          child = record
        end
      end
      assert.equals(ft.record(asking).uid, child.parent_uid)
      assert.equals(asking, ft.current_buf())
    end)

    it("opens a shell beside the asking tab without --under", function()
      local asking = H.sleep_tab { label = "first" }
      H.sleep_tab { label = "last" }
      ft.focus_buf(asking)
      local id = remote.open_tab(ft.record(asking).id, { label = "beside" })
      local tabs = ft.tabs()
      assert.equals("first", tabs[1].label)
      assert.equals("beside", tabs[2].label)
      assert.equals(id, tostring(tabs[2].id))
      assert.is_nil(tabs[2].parent_uid)
      assert.equals(asking, ft.current_buf())
    end)

    it("refuses a missing folder or a tab that isn't there", function()
      local asking = H.sleep_tab { label = "first" }
      assert.equals("", remote.open_tab(ft.record(asking).id, { cwd = "/no/such/folder" }))
      assert.equals("", remote.open_tab(99999, {}))
    end)
  end)

  describe("the scripts", function()
    it("floatterm-offer waits for your choice and prints it", function()
      local buf = H.sleep_tab { label = "api" }
      api.nvim_set_current_win(ft.window())
      local result = run("floatterm-offer", { file }, buf, function()
        H.wait(5000, function()
          return popup_lines() ~= nil
        end, "no pop-up")
        -- Its keys work once it has been showing for ARM_MS.
        settle()
        press "n"
      end)
      assert.equals(0, result.code, result.stderr)
      assert.equals("not opened", vim.trim(result.stdout))
    end)

    it("floatterm-offer gives the path back outside a floatterm tab", function()
      local result = run("floatterm-offer", { file }, nil)
      assert.equals(1, result.code)
      assert.equals(vim.fn.resolve(vim.fn.fnamemodify(file, ":p")), vim.fn.resolve(vim.trim(result.stdout)))
      assert.truthy(result.stderr:find("not running in a floatterm tab", 1, true))
    end)

    it("floatterm-tab new opens a tab and prints its id", function()
      local buf = H.sleep_tab { label = "api" }
      local result = run("floatterm-tab", { "new", "--under", "--label", "it's a \"test\"" }, buf)
      assert.equals(0, result.code, result.stderr)
      local id = vim.trim(result.stdout)
      local made
      for _, record in ipairs(ft.tabs()) do
        if tostring(record.id) == id then
          made = record
        end
      end
      assert.truthy(made, "no tab " .. id)
      assert.equals("it's a \"test\"", made.label)
      assert.equals(ft.record(buf).uid, made.parent_uid)
    end)

    it("floatterm-tab says so outside a floatterm tab", function()
      local result = run("floatterm-tab", { "new" }, nil)
      assert.equals(1, result.code)
      assert.truthy(result.stderr:find("not running in a floatterm tab", 1, true))
    end)
  end)
end)
