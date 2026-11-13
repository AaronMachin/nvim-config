-- lua/floatterm/emoji: an emoji per tab in the tab bar. Shell tabs get a random one no
-- other tab has, Claude tabs show ✳ until one is picked for them as a Claude tab.

local H = require "test_helpers"

local ft, emoji, tabbar

describe("emoji", function()
  before_each(function()
    H.isolate()
    ft = require "floatterm"
    emoji = require "floatterm.emoji"
    tabbar = require "floatterm.tabbar"
    H.isolate()
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  it("gives each shell tab an emoji from the set that no other tab has", function()
    local bufs = { H.sleep_tab(), H.sleep_tab(), H.sleep_tab() }
    tabbar.redraw()
    local seen = {}
    for _, buf in ipairs(bufs) do
      local record = ft.record(buf)
      assert.truthy(vim.tbl_contains(emoji.SET, record.emoji), record.emoji)
      assert.equals("shell", record.emoji_for)
      assert.is_nil(seen[record.emoji])
      seen[record.emoji] = true
    end
    -- It leads the shell's first line in the bar.
    assert.truthy(tabbar.lines()[1]:find(ft.record(bufs[1]).emoji, 1, true))
  end)

  it("keeps a tab's emoji once it has one", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    local first = ft.record(buf).emoji
    for _ = 1, 5 do
      emoji.ensure_all()
    end
    assert.equals(first, ft.record(buf).emoji)
  end)

  it("shows ✳ for a Claude tab until it has an emoji picked as a Claude tab", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    ft.update(buf, { kind = "claude" })
    assert.equals("✳", emoji.glyph(ft.record(buf)))
    ft.update(buf, { emoji = "🔐", emoji_for = "claude" })
    assert.equals("🔐", emoji.glyph(ft.record(buf)))
    -- Back to a shell, it's still the same piece of work.
    ft.update(buf, { kind = "shell" })
    emoji.ensure_all()
    assert.equals("🔐", emoji.glyph(ft.record(buf)))
  end)

  it("reuses the set once every emoji in it is taken", function()
    local buf = H.sleep_tab()
    tabbar.redraw()
    local record = ft.record(buf)
    local others = {}
    for i, e in ipairs(emoji.SET) do
      others[i] = { emoji = e }
    end
    H.stub(ft, "tabs", function()
      return vim.list_extend({ record }, others)
    end)
    assert.truthy(vim.tbl_contains(emoji.SET, emoji.random(record)))
  end)
end)

describe("emoji picked by Haiku", function()
  local bin, log

  before_each(function()
    H.isolate()
    ft = require "floatterm"
    emoji = require "floatterm.emoji"
    tabbar = require "floatterm.tabbar"
    H.isolate()
    H.stub(emoji, "picker", true)
    bin = H.fake_bin()
    log = H.tmpdir "claude" .. "/args"
  end)

  after_each(function()
    H.close_all_tabs()
    H.restore()
    H.close_floats()
  end)

  local function claude_says(body)
    H.script(bin, "claude", ('printf "%%s\\n" "$@" >>%q\n%s'):format(log, body))
  end

  local function claude_tab(fields)
    local buf = H.sleep_tab()
    tabbar.redraw()
    ft.update(buf, vim.tbl_extend("force", { kind = "claude", emoji_for = vim.NIL }, fields))
    -- What emoji.setup's listener does on every change to a tab.
    emoji.ensure_all()
    return buf
  end

  local function picked(buf)
    H.wait(5000, function()
      return ft.record(buf).emoji_for == "claude"
    end)
    return ft.record(buf).emoji
  end

  it("waits for Claude's title, then asks Haiku without the user's settings", function()
    claude_says 'echo "🔐"'
    local buf = claude_tab { last_prompt = "fix the sign-on page" }
    emoji.ensure_all()
    vim.wait(300)
    assert.equals("✳", emoji.glyph(ft.record(buf)))
    assert.is_false(H.exists(log))

    ft.update(buf, { title = "✳ Fixing the sign-on page" })
    emoji.ensure_all()
    assert.equals("🔐", picked(buf))
    assert.equals("🔐", emoji.glyph(ft.record(buf)))
    local args = H.read(log)
    assert.truthy(args:find("haiku", 1, true))
    assert.truthy(args:find("--setting-sources\n\n", 1, true))
    assert.truthy(args:find("Fixing the sign-on page", 1, true))
    assert.truthy(args:find("fix the sign-on page", 1, true))
  end)

  it("tells Haiku which emoji other tabs have", function()
    claude_says 'echo "🔑"'
    local shell = H.sleep_tab()
    tabbar.redraw()
    local buf = claude_tab { title = "✳ Tokens" }
    picked(buf)
    assert.truthy(H.read(log):find(ft.record(shell).emoji, 1, true))
  end)

  it("gives a random emoji when the reply isn't one emoji", function()
    claude_says 'echo "Sure! Here is one: 🔐"'
    local buf = claude_tab { title = "✳ Sign-on" }
    assert.truthy(vim.tbl_contains(emoji.SET, picked(buf)))
  end)

  it("gives a random emoji when claude fails", function()
    claude_says "exit 1"
    local buf = claude_tab { title = "✳ Sign-on" }
    assert.truthy(vim.tbl_contains(emoji.SET, picked(buf)))
  end)

  it("gives a random emoji straight away without claude installed", function()
    H.stub(vim.fn, "executable", function()
      return 0
    end)
    local buf = claude_tab { title = "✳ Sign-on" }
    assert.equals("claude", ft.record(buf).emoji_for)
    assert.truthy(vim.tbl_contains(emoji.SET, ft.record(buf).emoji))
  end)

  it("takes a variation selector off and refuses text", function()
    assert.equals("🏷", emoji.parse "🏷️\n")
    assert.equals("🔐", emoji.parse "  🔐 ")
    assert.is_nil(emoji.parse "A")
    assert.is_nil(emoji.parse "🔐🔑")
    assert.is_nil(emoji.parse "")
  end)
end)
