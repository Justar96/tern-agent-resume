# tern-agent-resume

Herdr-style agent resume for Tern. If Tern's daemon or the whole machine
restarts while Claude Code, Codex, pi or opencode is running in a pane, the
agent comes back in its own conversation, in the same folder, with the flags
you started it with.

```sh
tern plugin install github.com/Justar96/tern-agent-resume
# or, to edit a local checkout in place
tern plugin link <path-to-checkout>
tern plugin list        # should show: agent-resume … ready
```

## How it works

1. **Track.** Tern's shell integration reports every command line a pane
   runs (`command_started`). If it's an agent CLI, the plugin writes a record
   to its kv store with the pane, folder, command line and start time.
2. **Learn the session id.** About 15 s later, and every 2 min after that, it
   looks for the session file the agent wrote in that folder since it started.
   This is the same file herdr's integrations report:
   - Claude: `~/.claude/projects/<cwd with non-alphanumerics as ->/<id>.jsonl`
   - Codex: `~/.codex/sessions/**/rollout-*-<id>.jsonl`, matched on `"cwd"`
   - pi: `~/.pi/agent/sessions/--<cwd with / as ->--/<time>_<id>.jsonl`

   On Windows it runs through `wsl.exe -d <distro>` when the pane's folder is
   `\\wsl.localhost\…`. The status line shows `↻ claude 45476fb4` on tracked
   panes.
3. **Forget a clean exit.** When the agent exits 0 or 130 (Ctrl-C) the record
   is dropped. Any other status keeps it as `exited` so you can resume it
   from the palette. It is never resumed by itself. Closing the pane drops the
   record 10 s later, not at once, so a Tern that is going down with the
   machine doesn't forget what was running.
4. **Resume.** When a window starts, the plugin waits 4 s and looks for
   records whose pane no longer exists on any host. For each one it reuses an
   untouched shell Tern restored in the same folder, or opens a new tab
   there in the same session. Then it types the resume command:

   | Agent    | With a known id                          | Without            |
   |----------|------------------------------------------|--------------------|
   | claude   | `claude <your flags> --resume <id>`      | `--continue`       |
   | codex    | `codex resume <your flags> <id>`         | `resume --last`    |
   | pi       | `pi <your flags> --session <file>`       | `--continue`       |
   | omp      | `omp <your flags> --resume=<id>`         | `--continue`       |
   | opencode | `opencode <your flags> --session <id>`   | `--continue`       |
   | copilot  | `copilot <your flags> --resume=<id>`     | `--continue`       |
   | gemini   | `gemini <your flags> --resume <id>`      | `--resume latest`  |

   Unlike herdr (see herdr discussion #1080), your original flags and inline
   env are kept, for example `CLAUDE_CONFIG_DIR=… claude --dangerously-skip-permissions`.
   The initial prompt and any old `--resume`/`--continue` are dropped.

A window crash on its own needs nothing, because Tern's daemon keeps the
agents running. The records match live panes and the plugin leaves them alone.

## Palette

- **Agent Resume: Resume interrupted agents**: pick one, Resume all, or
  Forget these. This includes agents that crashed on their own.
- **Agent Resume: Show tracked agents**: state, session id, and the exact
  resume command. ↵ copies it.
- **Agent Resume: Forget all tracked agents**

## Settings

These are at the top of `common.luau`:

- `auto_resume = true`: resume on window start, like herdr's
  `resume_agents_on_restore`. Set it to `false` to only get a toast.
- `aliases = { cc = "claude" }`: other names you launch agents by.
- `clean_exit`, `restore_delay_ms`, `type_delay_ms`, `close_grace_ms`,
  `max_age_days`.

## Limits

- It needs Tern's shell integration to see command lines. That works in WSL
  bash, where Tern sets it up through `TERN_WSL_INTEGRATION`. Agents started as
  Tern's native agent blocks (omp via Carly or Overseer) aren't covered.
- Session ids come from the files on disk, not from hooks inside the agents.
  If two agents of the same CLI start in the same folder within a few
  seconds, they can swap ids. A `/resume` to another conversation inside a
  running agent isn't noticed. opencode, omp, copilot and gemini always use
  their "continue latest in this folder" form.
- Agents on remote hosts are only resumed while that host is connected, and
  their session ids aren't looked up (they use the continue form).
- A shutdown that kills Tern without warning is handled. If Tern does
  close its panes one by one first, records survive only when the machine
  goes down within the 10 s grace period.
