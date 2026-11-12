-- Window half: notices agent CLIs starting, learns their session ids, and after
-- a restart starts them again with their native resume flags.
local C = require("./common")
local CONFIG = C.CONFIG
local GROUP = "Agent Resume"
local TICK_MS = 30000
local RESOLVE_EVERY_S = 120

local resolving: { [string]: boolean } = {}
local statusCache: { [string]: string } = {}

local function shortCwd(cwd: string): string
	local _, linux = C.wslPath(cwd)
	local p = linux or cwd
	return p:match("[^/\\]+$") or p
end

local function label(rec): string
	return rec.agent .. " · " .. shortCwd(rec.cwd or "?")
end

local function ago(t: number?): string
	if not t then return "?" end
	local s = os.time() - t
	if s < 90 then return "just now" end
	if s < 5400 then return string.format("%d min ago", s // 60) end
	if s < 172800 then return string.format("%d h ago", s // 3600) end
	return string.format("%d d ago", s // 86400)
end

local function refreshStatus()
	local s = {}
	for k, rec in pairs(C.load()) do
		if rec.state == "running" then
			s[k] = if rec.id then rec.agent .. " " .. tostring(rec.id):sub(1, 8) else rec.agent
		end
	end
	statusCache = s
	tern.chrome.refresh()
end

-- Session ids ----------------------------------------------------------------

local function resolve(rec)
	local k = C.key(rec.pane)
	if resolving[k] then return end
	local argv = C.resolverArgv(rec)
	if not argv then return end
	resolving[k] = true
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = 15000 }, function(result, _fresh)
		resolving[k] = nil
		if result.status ~= 0 then
			tern.log.debug("agent-resume: resolver", rec.agent, result.status, result.stderr)
			return
		end
		local found = {}
		for line in result.stdout:gmatch("[^\r\n]+") do
			local id, path = line:match("^([^\t]+)\t(.+)$")
			if id then table.insert(found, { id = id, path = path }) end
		end
		local recs = C.load()
		local cur = recs[k]
		if not cur or cur.started ~= rec.started or cur.state ~= "running" then return end
		-- Two agents of one CLI in one folder: each keeps the session it has,
		-- and a new one takes the newest session nobody else holds.
		local claimed = {}
		for other, r in pairs(recs) do
			if other ~= k and r.agent == cur.agent and r.id then claimed[r.id] = true end
		end
		local pick = nil
		for _, f in ipairs(found) do
			if f.id == cur.id then pick = f; break end
		end
		if not pick then
			for _, f in ipairs(found) do
				if not claimed[f.id] then pick = f; break end
			end
		end
		cur.resolved = os.time()
		if pick then cur.id, cur.path = pick.id, pick.path end
		C.save(recs)
		refreshStatus()
	end)
	if not ok then
		resolving[k] = nil
		tern.log.warn("agent-resume: could not start the session lookup", err)
	end
end

local function resolveAll(cx)
	local mine = cx:window_key()
	local now = os.time()
	for _, rec in pairs(C.load()) do
		if rec.state == "running" and rec.window == mine
			and (not rec.resolved or now - rec.resolved >= RESOLVE_EVERY_S) then
			resolve(rec)
		end
	end
end

-- Tracking -------------------------------------------------------------------

local function tabName(cx, pane: number): string?
	local tab = cx.session:tab_of(pane)
	if not tab then return nil end
	for _, t in ipairs(cx.session:tabs()) do
		if t.id == tab then
			return if t.name and t.name ~= "" then t.name else nil
		end
	end
	return nil
end

local function sessionName(cx): string?
	local ok, s = pcall(function() return cx.sessions:current() end)
	return if ok and s then s.name else nil
end

local function track(cx, pane: number, line: string, startedAt: number?)
	local parsed = C.parse(line)
	if not parsed then return end
	local info = cx.session:pane(pane)
	local cwd = info and info.cwd or ""
	if cwd == "" then return end
	local host = cx.hosts:current()
	C.update(pane, function(old)
		local same = old and old.line == line and old.state == "running"
		return {
			pane = pane, agent = parsed.agent, line = line, cwd = cwd, env = parsed.env,
			id = (same and old.id) or parsed.id,
			path = if same then old.path else nil,
			started = if same then old.started else (startedAt or os.time()),
			resolved = if same then old.resolved else nil,
			resumed = if same then old.resumed else nil,
			state = "running",
			window = cx:window_key(),
			host = if host.kind == "local" then "local" else host.name,
			tab = tabName(cx, pane),
			session = sessionName(cx),
		}
	end)
	refreshStatus()
	-- Most CLIs write their session file with the first message.
	tern.timer(15000, function(fresh)
		if fresh then resolveAll(fresh) end
	end)
end

-- Agents that were already running when the plugin loaded.
local function adopt(cx)
	local recs = C.load()
	for _, p in ipairs(cx.session:panes()) do
		if p.kind == "terminal" and p.running and not recs[C.key(p.pane)] and C.parse(p.running.line) then
			track(cx, p.pane, p.running.line, os.time() - math.floor((p.running.ms or 0) / 1000))
		end
	end
end

-- Finding what was interrupted ---------------------------------------------

-- Every record whose agent isn't running any more, and whether a restart (not
-- the agent itself) ended it.
local function interrupted(cx)
	local recs = C.load()
	local live, count, connected = {}, 0, {}
	for _, h in ipairs(cx.hosts:list()) do
		connected[if h.kind == "local" then "local" else h.name] = h.state == "connected" or h.kind == "local"
		for _, p in ipairs(h.panes or {}) do
			live[C.key(p)] = true
			count += 1
		end
	end
	if count == 0 and #cx.session:panes() > 0 then
		tern.log.warn("agent-resume: the host lists no panes; not guessing what was lost")
		return {}
	end
	local now, changed, found = os.time(), false, {}
	local grace = CONFIG.close_grace_ms / 1000 + 2
	for k, rec in pairs(recs) do
		if now - (rec.started or 0) > CONFIG.max_age_days * 86400 then
			recs[k] = nil
			changed = true
		elseif live[k] then
			local info = cx.session:pane(rec.pane)
			if info and rec.state == "running" and not info.running and info.at_prompt
				and info.last and info.last.line == rec.line then
				-- It ended while the plugin wasn't listening.
				if CONFIG.clean_exit[info.last.status] then
					recs[k] = nil
				else
					rec.state, rec.exit = "exited", info.last.status
				end
				changed = true
			elseif info and rec.state == "exited" and info.at_prompt and not info.running then
				table.insert(found, { rec = rec, key = k, restart = false, here = rec.pane })
			end
		elseif not connected[rec.host or "local"] then
			-- Its machine isn't connected, so there's no telling whether it still runs.
		elseif rec.closing and now - rec.closing < grace then
			-- Closed a moment ago; the host half forgets it shortly.
		elseif rec.state == "resuming" and rec.by ~= cx:window_key() and now - (rec.claimed or 0) < 60 then
			-- Another window is bringing it back.
		else
			table.insert(found, { rec = rec, key = k, restart = rec.state ~= "exited" })
		end
	end
	if changed then C.save(recs) end
	table.sort(found, function(a, b) return (a.rec.started or 0) < (b.rec.started or 0) end)
	return found
end

-- Resuming -------------------------------------------------------------------

-- A shell Tern restored in the record's folder that nobody has used yet.
local function restoredShell(cx, rec, used): number?
	for _, p in ipairs(cx.session:panes()) do
		if p.kind == "terminal" and p.at_prompt and not p.running and not p.last and not p.parked
			and p.cwd == rec.cwd and not used[C.key(p.pane)] then
			return p.pane
		end
	end
	return nil
end

local function launch(cx, item, used): (boolean, string?)
	local rec = item.rec
	local cmd = C.resumeLine(rec)
	if not cmd then return false, "could not rebuild its command line" end

	local pane, delay = item.here or restoredShell(cx, rec, used), 0
	if pane and used[C.key(pane)] then pane = nil end
	if not pane then
		if rec.session then
			local sid = cx.session:find_session(rec.session)
			if sid then pcall(function() cx.sessions:switch(sid) end) end
		end
		local ok, res = pcall(function()
			return cx.hosts:terminal(if rec.host == "local" then "local" else rec.host, { cwd = rec.cwd })
		end)
		if not ok or not res then return false, tostring(res) end
		pane, delay = res, CONFIG.type_delay_ms
		local tab = cx.session:tab_of(pane)
		if tab then pcall(function() cx.layout:name_tab(tab, rec.tab or label(rec)) end) end
	end
	used[C.key(pane)] = true

	-- Move the record to its new pane now; command_started refreshes it there.
	local recs = C.load()
	recs[item.key] = nil
	local moved = table.clone(rec)
	moved.pane, moved.line, moved.state = pane, cmd, "running"
	moved.started, moved.resolved = os.time(), nil
	moved.closing, moved.exit, moved.by, moved.claimed = nil, nil, nil, nil
	moved.window = cx:window_key()
	moved.resumed = (rec.resumed or 0) + 1
	recs[C.key(pane)] = moved
	C.save(recs)

	tern.timer(delay, function(fresh)
		if not fresh then return end
		local ok, err = pcall(function() fresh:run(pane, cmd .. "\r") end)
		if not ok then fresh:toast("error", "Could not resume " .. label(moved), tostring(err)) end
	end)
	return true
end

local function resumeMany(cx, items)
	if #items == 0 then return end
	-- Claim them first, so a second window doesn't start them too.
	local recs, mine = C.load(), cx:window_key()
	for _, item in ipairs(items) do
		local r = recs[item.key]
		if r then r.state, r.by, r.claimed = "resuming", mine, os.time() end
	end
	C.save(recs)

	local before = sessionName(cx)
	local used, done, failed = {}, {}, {}
	for _, item in ipairs(items) do
		local ok, err = launch(cx, item, used)
		if ok then
			table.insert(done, label(item.rec))
		else
			table.insert(failed, label(item.rec) .. ": " .. (err or "?"))
			C.update(item.rec.pane, function(r)
				if r then r.state = item.rec.state end
				return r
			end)
		end
	end
	if before then
		local sid = cx.session:find_session(before)
		if sid then pcall(function() cx.sessions:switch(sid) end) end
	end
	refreshStatus()
	if #done > 0 then
		cx:toast("success", string.format("Resumed %d agent%s", #done, if #done == 1 then "" else "s"),
			table.concat(done, ", "))
	end
	if #failed > 0 then
		cx:toast("error", "Could not resume every agent", table.concat(failed, "; "))
	end
end

local function scan(cx)
	local found = interrupted(cx)
	local restarts = {}
	for _, item in ipairs(found) do
		if item.restart then table.insert(restarts, item) end
	end
	if #restarts == 0 then return end
	if CONFIG.auto_resume then
		resumeMany(cx, restarts)
	else
		cx:toast("info", string.format("%d agent%s stopped when Tern restarted", #restarts,
			if #restarts == 1 then "" else "s"), "Palette › Agent Resume: Resume interrupted agents")
	end
end

-- Palette --------------------------------------------------------------------

tern.command({ id = "resume", title = "Agent Resume: Resume interrupted agents", group = GROUP,
	run = function(cx)
		local found = interrupted(cx)
		if #found == 0 then
			cx:toast("info", "No interrupted agents")
			return
		end
		local items = {}
		if #found > 1 then
			table.insert(items, { label = "Resume all", detail = #found .. " agents", all = true })
		end
		for _, item in ipairs(found) do
			local why = if item.restart then "stopped by a restart"
				else "exited with status " .. tostring(item.rec.exit)
			table.insert(items, {
				label = label(item.rec),
				detail = why .. " · " .. ago(item.rec.started) .. (if item.rec.id then " · " .. tostring(item.rec.id):sub(1, 8) else ""),
				item = item,
			})
		end
		table.insert(items, { label = "Forget these", detail = "Don't offer them again", forget = true })
		cx:pick({ placeholder = "Resume which agent?", action = "resume", items = items })
			:next(function(choice, err, fresh)
				if not fresh then return end
				if err then fresh:toast("error", "Could not show interrupted agents", err); return end
				if not choice then return end
				if choice.forget then
					local recs = C.load()
					for _, item in ipairs(found) do recs[item.key] = nil end
					C.save(recs)
					fresh:toast("info", "Forgot " .. #found .. " interrupted agents")
				elseif choice.all then
					resumeMany(fresh, found)
				else
					resumeMany(fresh, { choice.item })
				end
			end)
	end })

tern.command({ id = "list", title = "Agent Resume: Show tracked agents", group = GROUP,
	run = function(cx)
		local items = {}
		for _, rec in pairs(C.load()) do
			local cmd = C.resumeLine(rec) or rec.line
			table.insert(items, {
				label = label(rec),
				detail = rec.state .. " · " .. (if rec.id then tostring(rec.id) else "session id not found yet") .. " · " .. cmd,
				copy = cmd,
			})
		end
		if #items == 0 then
			cx:toast("info", "No agents tracked yet", "Start claude, codex, pi or opencode in a terminal pane")
			return
		end
		cx:pick({ placeholder = "Tracked agents (↵ copies the resume command)", action = "copy", items = items })
			:next(function(choice, _err, fresh)
				if fresh and choice then
					fresh:copy(choice.copy)
					fresh:toast("info", "Copied", choice.copy)
				end
			end)
	end })

tern.command({ id = "forget", title = "Agent Resume: Forget all tracked agents", group = GROUP,
	run = function(cx)
		C.save({})
		refreshStatus()
		cx:toast("info", "Agent Resume forgot every tracked agent")
	end })

-- Status line: which panes would come back, and as which session.
tern.chrome.status(function(pane)
	local s = statusCache[C.key(pane.pane)]
	if not s then return nil end
	return { { text = "↻ " .. s, tone = "muted", command = "plugin.agent-resume.list" } }
end)

-- Events ---------------------------------------------------------------------

tern.on("command_started", function(ev, cx)
	local ok, err = pcall(track, cx, ev.pane, ev.line)
	if not ok then tern.log.warn("agent-resume: track", err) end
end)

tern.on("command_finished", function(ev, _cx)
	C.finished(ev.pane, ev.status, ev.line)
	refreshStatus()
end)

tern.on("pane_closed", function(ev, _cx)
	C.closed(ev.pane)
	refreshStatus()
end)

tern.on("window_start", function(cx)
	-- The first window looks first; others give it time to claim what it resumes.
	local delay = CONFIG.restore_delay_ms + (if cx:window_key() == "" then 0 else 3000)
	tern.timer(delay, function(fresh)
		if not fresh then return end
		local ok, err = pcall(scan, fresh)
		if not ok then tern.log.warn("agent-resume: scan", err) end
		pcall(adopt, fresh)
		refreshStatus()
	end)
end)

local function tick(cx)
	if cx then
		pcall(adopt, cx)
		pcall(resolveAll, cx)
	end
	tern.timer(TICK_MS, tick)
end
tern.timer(TICK_MS, tick)
