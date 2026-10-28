-- lua/floatterm/menu: the <leader>o keys, what which-key shows for each (with its
-- shortcut), and the panel.

local H = require "test_helpers"
local api = vim.api

local menu

local function desc(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  return map.desc
end

describe("terminal menu", function()
  before_each(function()
    H.isolate()
    menu = require "floatterm.menu"
    menu.setup()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  it("maps every action under <leader>o", function()
    for _, column in ipairs(menu.columns) do
      for _, entry in ipairs(column) do
        for key in pairs(entry[3]) do
          local map = vim.fn.maparg("<leader>o" .. key, "n", false, true)
          assert.is_not_nil(map.callback, "no <leader>o" .. key)
        end
      end
    end
  end)

  it("describes each with its direct shortcut", function()
    assert.equals("split ↔ float (Ctrl+Shift+d)", desc "<leader>od")
    assert.equals("full-screen (Ctrl+Shift+f)", desc "<leader>of")
    assert.equals("move left / resize (Ctrl+Shift+h)", desc "<leader>oh")
    assert.equals("move down / resize (Ctrl+Shift+j)", desc "<leader>oj")
    assert.equals("move tab earlier (Ctrl+Opt+←)", desc "<leader>o<")
    assert.equals("move tab later (Ctrl+Opt+→)", desc "<leader>o>")
    assert.equals("hide or show (Ctrl+\\)", desc "<leader>oq")
    assert.equals("selection to notes (Y in a tab)", desc "<leader>oy")
    assert.equals("go to tab 3", desc "<leader>o3")
    -- No shortcut: just what it does.
    assert.equals("notes on / off", desc "<leader>oe")
    assert.equals("add a note", desc "<leader>oa")
    assert.equals("refresh Claude's notes", desc "<leader>or")
  end)

  it("runs the action for the key pressed in the panel, listing every key", function()
    local panel_lines
    H.stub(vim.fn, "getcharstr", function()
      for _, win in ipairs(api.nvim_list_wins()) do
        local config = api.nvim_win_get_config(win)
        if config.relative ~= "" and config.zindex == 250 then
          panel_lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
        end
      end
      return "t"
    end)
    local ft = require "floatterm"
    local opened = 0
    H.stub(ft, "new_tab", function()
      opened = opened + 1
    end)
    menu.open()
    assert.equals(1, opened)
    local text = table.concat(panel_lines, "\n")
    assert.truthy(text:find("move / resize (Ctrl+Shift+h/j/k/l)", 1, true))
    assert.truthy(text:find("move tab earlier / later (Ctrl+Opt+←/→)", 1, true))
    assert.truthy(text:find("1-9", 1, true))
    -- The panel has gone.
    for _, win in ipairs(api.nvim_list_wins()) do
      assert.is_not.equals(250, api.nvim_win_get_config(win).zindex)
    end
  end)

  it("does nothing for a key it doesn't know", function()
    H.stub(vim.fn, "getcharstr", function()
      return "Z"
    end)
    menu.open()
    assert.equals(0, #require("floatterm").tabs())
  end)

  it("goes to a tab by number", function()
    local ft = require "floatterm"
    local a = H.sleep_tab()
    H.sleep_tab()
    vim.fn.maparg("<leader>o1", "n", false, true).callback()
    assert.equals(a, ft.current_buf())
  end)
end)
