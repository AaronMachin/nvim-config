-- Claude tabs for the grouping GIF: a planning session with one workstream already
-- under it, a second workstream not yet, and a dev server.
local demo = require "common"
demo.keys()
local ft = require "floatterm"
local groups = require "floatterm.groups"
local now = os.time()

local lead = demo.claude_tab("plan", { status = "needs_you", status_since = now - 40, title = "Plan support log search" }, {
  "> Split the support log search into workstreams",
  "",
  "Two workstreams, written to .superpowers/log-search/:",
  "  1. WS1 - the search API",
  "  2. WS2 - the console screen",
  "",
  "Which should go first?",
})
local ws1 = demo.claude_tab("ws1", { status = "working", status_since = now - 300, title = "WS1 search API" }, {
  "> Build WS1 from .superpowers/log-search/ws1.md",
  "",
  "Reading the plan...",
})
local ws2 = demo.claude_tab("ws2", { status = "done", status_since = now - 900, title = "WS2 console screen" }, {
  "> Build WS2 from .superpowers/log-search/ws2.md",
  "",
  "Done. The console screen lists results by site.",
})
local _, server = ft.new_tab({ "sh", "-c", "echo 'Listening on :3000'; sleep 3600" }, { label = "server", show = false })
ft.update(server, { command = "npm start" })
groups.set_parent(ws1, lead)
ft.focus_buf(lead, { typing = false })
ft.hide()
_ = ws2
