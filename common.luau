-- Shared by host.luau and window.luau: settings, the agent table, command-line
-- parsing, resume command building and the record store in tern.kv.

local M = {}

M.CONFIG = {
	-- Resume interrupted agents by itself when a window starts (herdr's
	-- resume_agents_on_restore). false: only toast, and resume from the palette.
	auto_resume = true,
	-- How long after a window starts to look, so restored panes have reported in.
	restore_delay_ms = 4000,
	-- How long a new shell gets before the resume command is typed into it.
	type_delay_ms = 900,
	-- A closed pane's record is dropped this much later, not at once: if Tern is
	-- shutting down with the machine, the timer never fires and the record survives.
	close_grace_ms = 10000,
	-- Exit statuses that mean "the user quit the agent"; anything else keeps the
	-- record so the agent can be resumed from the palette.
	clean_exit = { [0] = true, [130] = true },
	-- Forget records older than this many days.
	max_age_days = 7,
	-- Other names you launch agents by: alias or wrapper -> agent key below.
	aliases = { cc = "claude" },
}

M.KV = "agents"

local function set(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end

-- One entry per agent CLI.
--   value      flags whose next token is their value (so it isn't taken for a prompt)
--   strip      flags dropped before resuming -> how many values they take (0, 1, "opt")
--   id_flags   stripped flags whose value names a session
--   oneshot    flags that make the run non-interactive or sessionless: not tracked
--   subcommands first words that are not an interactive session: not tracked
--   session_sub a subcommand that resumes, whose next word is the id (codex resume ID)
--   positional "drop" (a prompt) or "keep" (a project directory)
--   resolver   true when the resolver script can find its session id on disk
--   resume(prefix, flags, id, path) -> command line
local AGENTS = {}

local function q(s: string): string
	if s:match("^[%w%-%._/:@%+=,]+$") then return s end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end
M.quote = q

AGENTS.claude = {
	value = set({ "--add-dir", "--agent", "--agents", "--allowedTools", "--allowed-tools",
		"--append-system-prompt", "--append-system-prompt-file", "--autocompact", "--betas",
		"--debug-file", "--disallowedTools", "--disallowed-tools", "--effort", "--fallback-model",
		"--file", "--json-schema", "--max-budget-usd", "--mcp-config", "--model", "--name", "-n",
		"--permission-mode", "--permission-prompts", "--plugin-dir", "--plugin-url",
		"--remote-control-session-name-prefix", "--setting-sources", "--settings",
		"--system-prompt", "--system-prompt-file", "--system-prompt-snapshot", "--tools" }),
	strip = { ["--resume"] = "opt", ["-r"] = "opt", ["--continue"] = 0, ["-c"] = 0,
		["--session-id"] = 1, ["--fork-session"] = 0, ["--from-pr"] = "opt", ["--teleport"] = "opt" },
	id_flags = set({ "--resume", "-r", "--session-id" }),
	oneshot = set({ "-p", "--print", "-v", "--version", "-h", "--help", "--bg", "--background",
		"--desktop", "--cloud", "--no-session-persistence", "--output-format", "--input-format" }),
	subcommands = set({ "mcp", "config", "doctor", "update", "upgrade", "install", "plugin",
		"plugins", "setup-token", "migrate-installer", "agents", "auth", "login", "logout" }),
	positional = "drop",
	resolver = true,
	resume = function(prefix, flags, id, _path)
		return prefix .. flags .. (if id then " --resume " .. q(id) else " --continue")
	end,
}

AGENTS.codex = {
	value = set({ "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
		"-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox",
		"-C", "--cd", "--add-dir", "-a", "--ask-for-approval" }),
	strip = { ["--last"] = 0, ["--all"] = 0, ["--include-non-interactive"] = 0 },
	id_flags = {},
	oneshot = set({ "-h", "--help", "-V", "--version" }),
	subcommands = set({ "exec", "e", "login", "logout", "mcp", "mcp-server", "app-server",
		"completion", "sandbox", "debug", "apply", "a", "cloud", "features", "help", "review", "fork" }),
	session_sub = "resume",
	positional = "drop",
	resolver = true,
	resume = function(prefix, flags, id, _path)
		return prefix .. " resume" .. flags .. (if id then " " .. q(id) else " --last")
	end,
}

AGENTS.pi = {
	value = set({ "--provider", "--model", "--api-key", "--system-prompt", "--append-system-prompt",
		"--session-dir", "--name", "-n", "--models", "--tools", "-t", "--exclude-tools", "-xt",
		"--thinking", "--extension", "-e", "--skill", "--prompt-template", "--theme", "--use-theme",
		"--tui-mode" }),
	strip = { ["--continue"] = 0, ["-c"] = 0, ["--resume"] = 0, ["-r"] = 0, ["--session"] = 1,
		["--session-id"] = 1, ["--fork"] = 1 },
	id_flags = set({ "--session", "--session-id" }),
	oneshot = set({ "-p", "--print", "--mode", "-h", "--help", "-v", "--version", "--export",
		"--list-models", "--no-session" }),
	subcommands = set({ "update", "install", "remove", "uninstall", "list", "config" }),
	positional = "drop",
	resolver = true,
	resume = function(prefix, flags, id, path)
		local ref = path or id
		return prefix .. flags .. (if ref then " --session " .. q(ref) else " --continue")
	end,
}

-- omp (oh-my-pi) is a pi fork; its session store isn't known here, so it
-- continues the latest session in the directory.
AGENTS.omp = {
	value = AGENTS.pi.value,
	strip = AGENTS.pi.strip,
	id_flags = set({ "--session", "--session-id", "--resume" }),
	oneshot = AGENTS.pi.oneshot,
	subcommands = set({ "update", "install", "remove", "plugin", "config" }),
	positional = "drop",
	resolver = false,
	resume = function(prefix, flags, id, _path)
		return prefix .. flags .. (if id then " --resume=" .. q(id) else " --continue")
	end,
}

AGENTS.opencode = {
	value = set({ "-m", "--model", "--agent", "--port", "--hostname", "--log-level" }),
	strip = { ["-c"] = 0, ["--continue"] = 0, ["-s"] = 1, ["--session"] = 1, ["--prompt"] = 1,
		["--fork"] = 0 },
	id_flags = set({ "-s", "--session" }),
	oneshot = set({ "-h", "--help", "-v", "--version" }),
	subcommands = set({ "run", "serve", "web", "auth", "models", "upgrade", "mcp", "agent",
		"github", "export", "import", "stats", "acp", "debug", "uninstall", "session", "attach" }),
	positional = "keep", -- `opencode [project]`
	resolver = false,
	resume = function(prefix, flags, id, _path)
		return prefix .. flags .. (if id then " --session " .. q(id) else " --continue")
	end,
}

AGENTS.copilot = {
	value = set({ "--model", "--add-dir", "--allow-tool", "--deny-tool", "--agent", "--log-dir",
		"--log-level", "--config-dir" }),
	strip = { ["--continue"] = 0, ["--resume"] = "opt" },
	id_flags = set({ "--resume" }),
	oneshot = set({ "-p", "--prompt", "-h", "--help", "-v", "--version" }),
	subcommands = set({ "help", "login", "logout", "update" }),
	positional = "drop",
	resolver = false,
	resume = function(prefix, flags, id, _path)
		return prefix .. flags .. (if id then " --resume=" .. q(id) else " --continue")
	end,
}

AGENTS.gemini = {
	value = set({ "-m", "--model", "--approval-mode", "--include-directories", "-e", "--extensions" }),
	strip = { ["--resume"] = "opt", ["-r"] = "opt" },
	id_flags = set({ "--resume", "-r" }),
	oneshot = set({ "-p", "--prompt", "-h", "--help", "-v", "--version", "--list-sessions" }),
	subcommands = set({ "mcp", "extensions", "update" }),
	positional = "drop",
	resolver = false,
	resume = function(prefix, flags, id, _path)
		return prefix .. flags .. " --resume " .. q(id or "latest")
	end,
}

M.AGENTS = AGENTS

-- Splits a shell line into words, keeping each word's raw text. Returns nil for
-- anything beyond one simple command (pipes, lists, redirections, substitutions).
local function tokenize(line: string)
	local toks = {}
	local i, n = 1, #line
	while true do
		while i <= n and line:sub(i, i):match("%s") do i += 1 end
		if i > n then break end
		local start, parts = i, {}
		while i <= n do
			local c = line:sub(i, i)
			if c:match("%s") then
				break
			elseif c == "'" then
				local j = line:find("'", i + 1, true)
				if not j then return nil end
				table.insert(parts, line:sub(i + 1, j - 1))
				i = j + 1
			elseif c == '"' then
				local j = i + 1
				while j <= n do
					local d = line:sub(j, j)
					if d == "\\" then j += 2 elseif d == '"' then break else j += 1 end
				end
				if j > n then return nil end
				local inner = line:sub(i + 1, j - 1):gsub('\\(["\\$`])', "%1")
				table.insert(parts, inner)
				i = j + 1
			elseif c == "\\" then
				table.insert(parts, line:sub(i + 1, i + 1))
				i += 2
			elseif c:match("[;&|<>()`]") or line:sub(i, i + 1) == "$(" then
				return nil
			else
				table.insert(parts, c)
				i += 1
			end
		end
		table.insert(toks, { raw = line:sub(start, i - 1), v = table.concat(parts) })
	end
	return toks
end
M.tokenize = tokenize

local function agentOf(word: string): string?
	local name = (word:match("[^/\\]+$") or word):lower():gsub("%.exe$", ""):gsub("%.cmd$", "")
	name = M.CONFIG.aliases[name] or name
	if AGENTS[name] then return name end
	return nil
end

export type Parsed = {
	agent: string,
	prefix: string, -- env assignments and the program, as typed
	flags: string, -- kept flags (leading space each), as typed
	env: { [string]: string },
	id: string?,
}

-- What an agent command line runs, or nil when it isn't an interactive agent session.
function M.parse(line: string): Parsed?
	local toks = tokenize(line)
	if not toks or #toks == 0 then return nil end
	local i, env, prefix = 1, {}, {}
	while toks[i] do
		local name, val = toks[i].v:match("^([%a_][%w_]*)=(.*)$")
		if name then
			env[name] = val
			table.insert(prefix, toks[i].raw)
			i += 1
		elseif toks[i].v == "exec" or toks[i].v == "command" or toks[i].v == "env" then
			table.insert(prefix, toks[i].raw)
			i += 1
		else
			break
		end
	end
	if not toks[i] then return nil end
	local agent = agentOf(toks[i].v)
	if not agent then return nil end
	table.insert(prefix, toks[i].raw)
	local def = AGENTS[agent]

	local kept, positional, id = {}, {}, nil
	local j = i + 1
	while j <= #toks do
		local t = toks[j]
		local v = t.v
		local flag = v:sub(1, 1) == "-" and #v > 1
		local name = if flag then (v:match("^(%-%-?[^=]+)=") or v) else v
		local inline = flag and v:find("=", 1, true) ~= nil
		if v == "--" then
			for k = j + 1, #toks do table.insert(positional, toks[k]) end
			break
		elseif flag and def.oneshot[name] then
			return nil
		elseif flag and def.strip[name] ~= nil then
			local n, val = def.strip[name], nil
			if inline then
				val = v:match("=(.*)$")
			elseif toks[j + 1] and (n == 1 or (n == "opt" and toks[j + 1].v:sub(1, 1) ~= "-")) then
				val = toks[j + 1].v
				j += 1
			end
			if def.id_flags[name] and val and val ~= "" then id = val end
		elseif flag then
			table.insert(kept, t.raw)
			if not inline and def.value[name] and toks[j + 1] then
				table.insert(kept, toks[j + 1].raw)
				j += 1
			end
		else
			table.insert(positional, t)
		end
		j += 1
	end

	if positional[1] then
		local first = positional[1].v
		if def.session_sub and first == def.session_sub then
			table.remove(positional, 1)
			if positional[1] then id = positional[1].v; table.remove(positional, 1) end
			positional = {} -- whatever follows the id is a prompt
		elseif def.subcommands[first] then
			return nil
		end
	end
	if def.positional == "keep" then
		for _, t in ipairs(positional) do table.insert(kept, t.raw) end
	end

	local flags = ""
	for _, raw in ipairs(kept) do flags ..= " " .. raw end
	return { agent = agent, prefix = table.concat(prefix, " "), flags = flags, env = env, id = id }
end

-- The command that brings a record's agent back into its session.
function M.resumeLine(rec): string?
	local p = M.parse(rec.line)
	if not p then return nil end
	local def = AGENTS[p.agent]
	return def.resume(p.prefix, p.flags, rec.id or p.id, rec.path)
end

function M.key(pane: number): string
	return string.format("%.0f", pane)
end

-- The record store: { [paneKey] = record }, shared by both halves and every window.
function M.load(): { [string]: any }
	local ok, v = pcall(tern.kv.get, M.KV)
	if ok and type(v) == "table" then return v end
	return {}
end

function M.save(recs)
	local ok, err = pcall(tern.kv.set, M.KV, recs)
	if not ok then tern.log.warn("agent-resume: could not save records", err) end
end

function M.update(pane: number, fn: (any) -> any)
	local recs = M.load()
	local k = M.key(pane)
	local before = recs[k]
	local after = fn(before)
	if after ~= before or after ~= nil then
		recs[k] = after
		M.save(recs)
	end
end

-- The agent's command ended in the pane: a clean quit forgets it, anything
-- else (a crash) keeps it for a resume from the palette.
function M.finished(pane: number, status: number, line: string?)
	M.update(pane, function(rec)
		if not rec or rec.state ~= "running" then return rec end
		if line and rec.line ~= line then return rec end
		if M.CONFIG.clean_exit[status] then return nil end
		rec.state = "exited"
		rec.exit = status
		return rec
	end)
end

-- The pane went away. Forget it a little later, so that a Tern going down with
-- the machine doesn't forget everything it was running.
function M.closed(pane: number)
	local stamp = nil
	M.update(pane, function(rec)
		if not rec then return nil end
		rec.closing = os.time()
		stamp = rec.closing
		return rec
	end)
	if not stamp then return end
	tern.timer(M.CONFIG.close_grace_ms, function()
		M.update(pane, function(rec)
			if rec and rec.closing == stamp then return nil end
			return rec
		end)
	end)
end

-- Finds the session files an agent wrote in a directory since a time, newest
-- first, one "<id>\t<path>" per line. Runs on the machine (or WSL distro) the
-- agent runs on. Args: agent, cwd, UTC stamp as touch -t takes it.
M.RESOLVER = [==[
agent=$1; cwd=$2; ts=$3
stamp=$(mktemp) || exit 1
trap 'rm -f "$stamp"' EXIT
TZ=UTC0 touch -t "$ts" "$stamp" || exit 1
newest() { find "$1" $2 -type f -name "$3" -newer "$stamp" -exec ls -t {} + 2>/dev/null; }
tilde() { case $1 in "~") printf %s "$HOME" ;; "~/"*) printf %s "$HOME/${1#??}" ;; *) printf %s "$1" ;; esac; }
[ -n "$CLAUDE_CONFIG_DIR" ] && CLAUDE_CONFIG_DIR=$(tilde "$CLAUDE_CONFIG_DIR")
[ -n "$CODEX_HOME" ] && CODEX_HOME=$(tilde "$CODEX_HOME")
[ -n "$PI_CODING_AGENT_DIR" ] && PI_CODING_AGENT_DIR=$(tilde "$PI_CODING_AGENT_DIR")
case $agent in
claude)
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf %s "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
  [ -d "$dir" ] || exit 0
  newest "$dir" "-maxdepth 1" '*.jsonl' | while IFS= read -r f; do
    b=${f##*/}; printf '%s\t%s\n' "${b%.jsonl}" "$f"
  done ;;
codex)
  root="${CODEX_HOME:-$HOME/.codex}/sessions"
  [ -d "$root" ] || exit 0
  newest "$root" "" 'rollout-*.jsonl' | while IFS= read -r f; do
    head -c 8192 "$f" | head -n 1 | grep -qF "\"cwd\":\"$cwd\"" || continue
    b=${f##*/}; b=${b%.jsonl}
    printf '%s\t%s\n' "$(printf %s "$b" | tail -c 36)" "$f"
  done ;;
pi)
  dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions/--$(printf %s "$cwd" | sed 's#^/##; s#/#-#g')--"
  [ -d "$dir" ] || exit 0
  newest "$dir" "-maxdepth 1" '*.jsonl' | while IFS= read -r f; do
    b=${f##*/}; b=${b%.jsonl}; printf '%s\t%s\n' "${b#*_}" "$f"
  done ;;
esac
]==]

-- `\\wsl.localhost\Distro\home\me` (or `\\wsl$\…`) -> "Distro", "/home/me".
function M.wslPath(cwd: string): (string?, string?)
	local distro, rest = cwd:match("^\\\\wsl%.localhost\\([^\\]+)(.*)$")
	if not distro then distro, rest = cwd:match("^\\\\wsl%$\\([^\\]+)(.*)$") end
	if not distro then return nil, nil end
	rest = rest:gsub("\\", "/")
	if rest == "" then rest = "/" end
	return distro, rest
end

-- argv that runs the resolver where the record's agent runs, or nil when it can't.
function M.resolverArgv(rec): { string }?
	local def = AGENTS[rec.agent]
	if not def or not def.resolver or rec.host ~= "local" then return nil end
	local stamp = os.date("!%Y%m%d%H%M.%S", rec.started - 5)
	local env = {}
	for k, v in pairs(rec.env or {}) do table.insert(env, k .. "=" .. v) end
	local argv
	local distro, path = M.wslPath(rec.cwd)
	if distro then
		argv = { "wsl.exe", "-d", distro, "--exec", "env" }
	elseif tern.runtime.os == "windows" then
		return nil -- an agent in native Windows shells: no resolver there
	else
		argv = { "env" }
		path = rec.cwd
	end
	for _, e in ipairs(env) do table.insert(argv, e) end
	for _, a in ipairs({ "/bin/sh", "-c", M.RESOLVER, "sh", rec.agent, path :: string, stamp }) do
		table.insert(argv, a)
	end
	return argv
end

return M
