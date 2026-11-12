-- Host half: runs in the session daemon, so it hears agents finish and panes
-- exit even while no window is open.
local C = require("./common")

tern.on("command_finished", function(ev, _cx)
	C.finished(ev.pane, ev.status, ev.line)
end)

tern.on("pane_exited", function(ev, _cx)
	C.closed(ev.pane)
end)
