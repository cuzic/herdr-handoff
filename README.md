# herdr-handoff

One command for the "write a handoff note → `/clear` → resume from that note" cycle,
for [Claude Code](https://code.claude.com) running inside a
[herdr-core](https://herdr.dev/core/) (`hc`) terminal.

```text
/handoff
  1. Claude writes ~/handoffs/<timestamp>-<repo>.md and ends its turn
  2. a detached driver waits for the turn to end (hc wait)
  3. checks the note, sends /clear
  4. sends "read <note> and continue"
```

The driver is outside the session being cleared, so no workflow state lives in the
conversation. It never sends `/clear` when the terminal is blocked (e.g. a permission
prompt), errored, or the note is missing.

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
/handoff                 # or /herdr-handoff:handoff
/handoff 次は PR #12 のレビュー対応から   # optional note for the next session
```

Outside herdr-core, `/handoff` still writes the note and tells you to `/clear` and
resume by hand.

## Settings (environment variables)

| Variable | Default | |
|---|---|---|
| `HERDR_HANDOFF_DIR` | `~/handoffs` | where notes and the log (`.hc-handoff.log`) go |
| `HERDR_HANDOFF_PROMPT` | Japanese resume prompt | `{file}` is replaced with the note path |

## How it decides "the turn has ended"

`hc get <t> --json` → `.status.state`: `working` keeps waiting (via `hc wait`),
`idle`/`done` that stays the same for 2 s proceeds, anything else (`blocked`, `error`,
missing) aborts. One driver per terminal (`flock`).

## License

MIT
