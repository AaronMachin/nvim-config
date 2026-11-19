-- lua/floatterm/decisions: decisions waiting for you per Claude tab, from the
-- decisions mod's files.

local H = require "test_helpers"

local decisions, root

local function decision(store, id, fields)
  H.write(root .. "/" .. store .. "/" .. id .. ".json", vim.json.encode(fields))
end

describe("decisions waiting", function()
  before_each(function()
    decisions = require "floatterm.decisions"
    root = H.tmpdir "decisions"
    H.stub(decisions, "root", root)
    H.stub(decisions, "CHECK_MS", 0)
    decisions.reset()
  end)

  after_each(function()
    H.restore()
  end)

  local tab = { kind = "claude", session_id = "s1" }

  it("counts only this session's open and live ones that need you", function()
    decision("app-1", "d1", { session = "s1", state = "open", section = "needs-you" })
    decision("app-1", "d2", { session = "s1", state = "live", section = "needs-you" })
    decision("app-1", "d3", { session = "s1", state = "ready", section = "needs-you" })
    decision("app-1", "d4", { session = "s1", state = "sent", section = "needs-you" })
    decision("app-1", "d5", { session = "s1", state = "open", section = "claudes-call" })
    decision("app-1", "d6", { session = "s2", state = "open", section = "needs-you" })
    decision("other-2", "d1", { session = "s1", state = "open" })
    H.write(root .. "/app-1/session-s1.json", "{}")
    H.write(root .. "/app-1/d9.json", "not json")
    assert.equals(3, decisions.count(tab))
    assert.equals(1, decisions.count { kind = "claude", session_id = "s2" })
  end)

  it("picks up a new one, and one answered since", function()
    decision("app-1", "d1", { session = "s1", state = "open", section = "needs-you" })
    assert.equals(1, decisions.count(tab))
    decision("app-1", "d2", { session = "s1", state = "open", section = "needs-you" })
    assert.equals(2, decisions.count(tab))
    decision("app-1", "d1", { session = "s1", state = "ready", section = "needs-you", answer = { option = 1 } })
    assert.equals(1, decisions.count(tab))
    os.remove(root .. "/app-1/d2.json")
    assert.equals(0, decisions.count(tab))
  end)

  it("is 0 for a shell, a tab without a session, or without the mod", function()
    decision("app-1", "d1", { session = "s1", state = "open", section = "needs-you" })
    assert.equals(0, decisions.count { kind = "shell", session_id = "s1" })
    assert.equals(0, decisions.count { kind = "claude" })
    H.stub(decisions, "root", root .. "/missing")
    decisions.reset()
    assert.equals(0, decisions.count(tab))
  end)
end)
