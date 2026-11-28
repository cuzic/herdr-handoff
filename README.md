# herdr-handoff

Two skills for the "write a handoff note → `/clear` → continue from that note" cycle,
for [Claude Code](https://code.claude.com), [Codex](https://github.com/openai/codex) and
Muse Code running inside a [herdr-core](https://herdr.dev/core/) (`hc`) terminal. One
plugin serves all three: Codex and Muse Code load Claude-format plugins (skills and hooks).

| Skill | After `/clear` |
|---|---|
| `/handoff` | the note is loaded into the new conversation, which then **waits for you** |
| `/handoff-auto` | the note is loaded, and Claude **picks the best goal from it and runs autonomously** |

```text
/handoff | /handoff-auto
  1. the agent writes ~/handoffs/<timestamp>-<repo>.md, arms the reload, ends its turn
  2. a detached driver waits for the turn to end, checks the note, sends /clear
  3. a SessionStart hook (source "clear") puts the note into the new context
  4. auto only: the driver sends "set a goal and execute"
```

Claude Code runs the SessionStart hook on `/clear` itself, so the driver waits for it before
step 4. Codex and Muse Code run it with the first prompt of the new session, so in auto mode
the prompt of step 4 is what loads the note, and in load mode the note is loaded with your
next message (the arm is kept for 24 h).

The driver is outside the session being cleared, so no workflow state lives in the
conversation. It never sends `/clear` when the terminal is blocked (e.g. a permission
prompt), errored, or the note is missing. After `/clear` it waits for the hook's signal,
not for a turn end (`/clear` does not always report one).

## Install

Claude Code:

```text
/plugin marketplace add cuzic/herdr-handoff
/plugin install herdr-handoff@herdr-handoff
```

Codex (then trust the plugin's 2 hooks at the next start: "Hooks need review" → trust):

```sh
codex plugin marketplace add cuzic/herdr-handoff   # or a local checkout path
codex plugin add herdr-handoff@herdr-handoff
```

Muse Code (hooks stay off until approved):

```sh
muse plugins install /path/to/herdr-handoff --scope user
muse plugins approve herdr-handoff
# after pulling changes: muse plugins update herdr-handoff && muse plugins approve herdr-handoff
```

Requirements: `hc` (herdr-core), `jq`, `flock`, `setsid` (util-linux). Linux / macOS
with util-linux; Muse Code needs Linux (see below).

## Use

```text
/handoff                 # Claude Code: or /herdr-handoff:handoff — load only
/handoff-auto            # Claude Code: or /herdr-handoff:handoff-auto — load, set a goal, run
/handoff 次は PR #12 のレビュー対応から   # optional note for the next session
$handoff / $handoff-auto # Codex
/handoff / /handoff-auto # Muse Code
```

Codex and Muse Code sandbox shell commands, and the note goes to `~/handoffs` and the driver
talks to `hc`, so the skill runs its one command (`hc-handoff.sh start <mode> -`, note on
stdin) outside the sandbox: approve it when asked.

Outside herdr-core, the skills write the note and arm the hook; run `/clear` yourself
and the note is loaded (for auto, then tell it to go).

## Settings (environment variables)

| Variable | Default | |
|---|---|---|
| `HERDR_HANDOFF_DIR` | `~/handoffs` | where notes, state (`.state/`) and the log (`.hc-handoff.log`) go |
| `HERDR_HANDOFF_AUTO_PROMPT` | Japanese "set a goal and execute" prompt | `{file}` is replaced with the note path |
| `HERDR_HANDOFF_MAX_WAIT` | `14400` | seconds to wait for the reply to end before giving up |
| `HERDR_HANDOFF_SETTLE` | `0.5` | seconds between the note being loaded and the auto prompt |

An armed reload expires after 2 hours (24 hours for load mode in Codex / Muse Code), and is
consumed by the first session start after `/clear`.

## How it decides "the turn has ended"

A `Stop` hook marks the end of the main reply. In Claude Code, background agents and shells
keep the terminal `working` after that, but they survive `/clear`, so the driver does not
wait for them; the note records them so the next conversation can pick them up. Codex and
Muse Code refuse `/clear` while a turn is active, so there the driver also waits for
`idle`/`done`. Muse Code does not pass `HC_TERMINAL_ID` to hooks; the hook finds it in the
environment of its parent processes through `/proc`, so with Muse Code this works on Linux
only. If the hook did not
run, the fallback is `hc get <t> --json` → `.status.state`: `idle`/`done` that stays the
same for 2 s proceeds. `blocked` (after the first 15 s, which may still show the approval
of the skill's own command), `error` or a missing terminal aborts without `/clear`.
One driver per terminal (`flock`): a new handoff stops a driver still waiting from an
earlier one, and a driver whose note is no longer the armed one stops without `/clear`.
In Claude Code, if the note has not been loaded 60 s after `/clear`, the driver stops
without sending the auto prompt. In Codex / Muse Code the driver only checks, for 60 s after
the auto prompt, that the note was loaded (load mode does not wait). The arm records which
agent it is for; a session start in another agent in the same terminal drops it.

## License

MIT
