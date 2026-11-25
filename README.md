# herdr-handoff

Two commands for the "write a handoff note → `/clear` → continue from that note" cycle,
for [Claude Code](https://code.claude.com) running inside a
[herdr-core](https://herdr.dev/core/) (`hc`) terminal.

| Command | After `/clear` |
|---|---|
| `/handoff` | the note is loaded into the new conversation, which then **waits for you** |
| `/handoff-auto` | the note is loaded, and Claude **picks the best goal from it and runs autonomously** |

```text
/handoff | /handoff-auto
  1. Claude writes ~/handoffs/<timestamp>-<repo>.md, arms the reload, ends its turn
  2. a detached driver waits for the turn to end, checks the note, sends /clear
  3. a SessionStart hook (source "clear") puts the note into the new context
  4. auto only: once the hook has fired, the driver sends "set a goal and execute"
```

The driver is outside the session being cleared, so no workflow state lives in the
conversation. It never sends `/clear` when the terminal is blocked (e.g. a permission
prompt), errored, or the note is missing. After `/clear` it waits for the hook's signal,
not for a turn end (`/clear` does not always report one).

## Install

In Claude Code:

```text
/plugin marketplace add cuzic/herdr-handoff
/plugin install herdr-handoff@herdr-handoff
```

Requirements: `hc` (herdr-core), `jq`, `flock`, `setsid` (util-linux). Linux / macOS
with util-linux.

## Use

```text
/handoff                 # or /herdr-handoff:handoff — load only
/handoff-auto            # or /herdr-handoff:handoff-auto — load, set a goal, run
/handoff 次は PR #12 のレビュー対応から   # optional note for the next session
```

Outside herdr-core, the commands write the note and arm the hook; run `/clear` yourself
and the note is loaded (for auto, then tell it to go).

## Settings (environment variables)

| Variable | Default | |
|---|---|---|
| `HERDR_HANDOFF_DIR` | `~/handoffs` | where notes, state (`.state/`) and the log (`.hc-handoff.log`) go |
| `HERDR_HANDOFF_AUTO_PROMPT` | Japanese "set a goal and execute" prompt | `{file}` is replaced with the note path |

An armed reload expires after 2 hours, and is consumed by the first `/clear`.

## How it decides "the turn has ended"

`hc get <t> --json` → `.status.state`: `working` keeps waiting (via `hc wait`),
`idle`/`done` that stays the same for 2 s proceeds, anything else (`blocked`, `error`,
missing) aborts. One driver per terminal (`flock`). If the hook has not fired 60 s
after `/clear`, the driver stops without sending anything.

## License

MIT
