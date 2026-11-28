#!/usr/bin/env bash
# hc-handoff.sh — handoff → /clear → reload (→ resume) for Claude Code, Codex or Muse Code in a herdr-core (hc) terminal.
#
#   hc-handoff.sh path                       print a fresh handoff file path (creates the dir)
#   hc-handoff.sh start <load|auto> <file>   arm the reload and detach the driver; prints "launched"
#                                            (<file> = "-": read the note from stdin, print its path)
#   hc-handoff.sh run <terminal> <mode> <file>  the driver itself (normally started by `start`)
#   hc-handoff.sh session-start              SessionStart hook: after /clear, load the armed note
#   hc-handoff.sh stop                       Stop hook: tell the driver the main reply has ended
#
# Modes:
#   load  /clear, then the SessionStart hook puts the note into the new context. Nothing else.
#   auto  same, then the driver sends a prompt: pick the best goal from the note and execute it.
#
# The driver waits for the current reply to end (Stop hook; background agents may keep running,
# they survive /clear), checks the note, and sends /clear. It never
# sends /clear if the terminal is blocked, errored, or the note is missing. After /clear it
# waits for the hook's "loaded" signal (not for a turn to end) before sending anything.
#
# Environment:
#   HERDR_HANDOFF_DIR          where notes go (default: ~/handoffs)
#   HERDR_HANDOFF_AUTO_PROMPT  prompt sent in auto mode; "{file}" is replaced with the path
#   HERDR_HANDOFF_MAX_WAIT     seconds to wait for the reply to end before giving up (14400)
#   HERDR_HANDOFF_SETTLE       seconds to wait after the note is loaded before the auto prompt (0.5)
set -uo pipefail

DIR="${HERDR_HANDOFF_DIR:-$HOME/handoffs}"
STATE="$DIR/.state"
LOG="$DIR/.hc-handoff.log"
DEFAULT_AUTO_PROMPT='引継書 {file} の内容はコンテキストに読み込み済みです。まず実際のファイル・git・プロセスの状態を確認して引継書と食い違いがないか確かめ、引継書・ユーザーの制約・メモリを踏まえて最適と思われるゴールを自分で設定し、ゴールと完了条件を 3 行以内で宣言してから、確認待ちをせずに自律的に実行してください。不可逆な操作や外部への公開（push・マージ・投稿・削除など）は、引継書かメモリで許可されているもの以外は実行前に確認してください。'

die() { echo "hc-handoff: $*" >&2; exit 1; }
log() { mkdir -p "$DIR"; printf '%s [%s] %s\n' "$(date '+%F %T')" "${LOGTAG:-?}" "$*" >>"$LOG"; }

# The hc terminal this process runs in. Some agents (Muse Code) strip HC_TERMINAL_ID from
# the hook environment, so fall back to the nearest ancestor that has it (Linux /proc).
hc_terminal() {
  if [[ -n "${HC_TERMINAL_ID:-}" ]]; then printf '%s' "$HC_TERMINAL_ID"; return; fi
  local pid=$PPID v n=0
  while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 && n++ < 20 )); do
    v=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^HC_TERMINAL_ID=//p' | head -n1)
    [[ -n $v ]] && { printf '%s' "$v"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

# Which agent runs this hook (hc's app names), from where the plugin was installed.
hook_app() {
  if [[ -n "${MUSE_PLUGIN_ROOT:-}${MUSE_SESSION_ID:-}" ]]; then printf muse
  elif [[ $0 == */.codex/* ]]; then printf codex
  elif [[ $0 == */.claude/* ]]; then printf claude-code
  fi
}

# One slot per terminal (or per directory outside herdr-core).
slot_key() {
  local t; t=$(hc_terminal)
  if [[ -n $t ]]; then printf 'hc-%s' "$t"
  else printf 'dir-%s' "$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"; fi
}

cmd_path() {
  mkdir -p "$DIR" || die "cannot create $DIR"
  local base n=1 f
  base="$DIR/$(date +%Y%m%d-%H%M%S)-$(basename "$PWD")"
  f="$base.md"
  while [[ -e $f ]]; do f="$base-$((++n)).md"; done
  printf '%s\n' "$f"
}

cmd_start() {
  local mode="${1:?usage: start <load|auto> <file>}" f="${2:?usage: start <load|auto> <file>}"
  [[ $mode == load || $mode == auto ]] || die "mode must be load or auto"
  if [[ $f == - ]]; then
    # Note on stdin: save it to a fresh path (one command for sandboxed agents). Drop a
    # heredoc terminator that was indented and so did not end the heredoc.
    f=$(cmd_path) || exit 1
    sed '/^[[:space:]]*HANDOFF_EOF[[:space:]]*$/d' >"$f" || die "cannot write $f"
    echo "$f"
  fi
  [[ -s "$f" ]] || die "handoff file is missing or empty: $f"
  grep -q '^[[:space:]]*# ' "$f" || die "handoff file has no '# ' heading: $f"
  f=$(realpath "$f")
  mkdir -p "$STATE" || die "cannot create $STATE"
  local t key; t=$(hc_terminal); key=$(slot_key)

  # A driver still waiting from an earlier handoff in this terminal would act on its own
  # (older) note: stop it before arming the new one.
  if [[ -f "$STATE/$key.lock" ]] && ! flock -n "$STATE/$key.lock" true; then
    local old; old=$(cat "$STATE/$key.pid" 2>/dev/null)
    [[ $old =~ ^[0-9]+$ ]] && kill "$old" 2>/dev/null
    local i; for i in $(seq 1 30); do flock -n "$STATE/$key.lock" true && break; sleep 0.1; done
    flock -n "$STATE/$key.lock" true || die "an earlier handoff driver is still running (pid ${old:-?})"
  fi

  # Arm the SessionStart hook. Works even without hc (manual /clear).
  printf '%s\n%s\n%s\n%s\n' "$mode" "$f" 120 "" >"$STATE/$key.pending"
  rm -f "$STATE/$key.loaded" "$STATE/$key.stopped"

  if [[ -z $t ]] || ! command -v hc >/dev/null || ! command -v jq >/dev/null; then
    echo "armed (no hc): run /clear yourself; the note will be loaded"
    return 0
  fi
  setsid -f "$0" run "$t" "$mode" "$f" >/dev/null 2>&1 </dev/null || die "failed to detach"
  echo launched
}

cmd_run() {
  local T="${1:?terminal}" mode="${2:?mode}" F="${3:?file}"
  LOGTAG=$T
  local key="hc-$T"
  # Talk to hc as an outside controller, not as a child of the terminal we drive.
  unset HC_TERMINAL_ID HC_SCOPE
  mkdir -p "$STATE"

  exec 9>"$STATE/$key.lock"
  flock -n 9 || { log "already running; abort"; exit 1; }
  echo $$ >"$STATE/$key.pid"

  status() { hc get "$T" --json 2>/dev/null | jq -r '.status.state // "none"'; }
  # Only touch the slot while it still holds our note (a newer handoff replaces it).
  ours() { [[ $(sed -n 2p "$STATE/$key.pending" 2>/dev/null) == "$F" ]]; }
  disarm() { ours && rm -f "$STATE/$key.pending"; }
  # arm <expiry-minutes>: (re-)write the slot the SessionStart hook consumes.
  arm() { printf '%s\n%s\n%s\n%s\n' "$mode" "$F" "$1" "$app" >"$STATE/$key.pending"; }

  # Claude Code runs the SessionStart hook on /clear itself. Codex and Muse Code run it
  # lazily, when the first prompt of the new session is submitted. Unknown: assume lazy,
  # which also works (more slowly) for Claude Code.
  local app="" lazy=1 n
  for n in 1 2 3; do
    app=$(hc get "$T" --json 2>/dev/null | jq -r '.status.app // .agent // ""')
    [[ -n $app ]] && break; sleep 0.5
  done
  [[ $app == claude-code ]] && lazy=0

  log "start mode=$mode app=${app:-?} file=$F"

  # 1. Wait until the /handoff reply ends. The Stop hook touches <key>.stopped when the main
  #    reply ends, even while background agents/shells keep the terminal "working"; those
  #    survive /clear, so they need not finish first. Fallback (hook did not run): idle/done
  #    stable for 2s. error/missing aborts; blocked aborts too, except right after start
  #    (hc may still report the approval prompt that let this script run).
  local t0; t0=$(date +%s)
  local deadline=$(( t0 + ${HERDR_HANDOFF_MAX_WAIT:-14400} )) s i=0
  fresh() { (( $(date +%s) - t0 < 15 )); }
  while :; do
    (( $(date +%s) < deadline )) || { log "timeout waiting for turn end; abort"; disarm; exit 1; }
    if [[ -e "$STATE/$key.stopped" ]]; then
      rm -f "$STATE/$key.stopped"
      s=$(status)
      while [[ $s == blocked ]] && fresh; do sleep 0.5; s=$(status); done
      # Lazy agents refuse /clear while the turn is still winding down: wait for idle/done.
      while (( lazy )) && [[ $s == working ]] && (( $(date +%s) < deadline )); do
        sleep 0.2; s=$(status)
      done
      case "$s" in
        working|idle|done) log "reply ended (Stop hook, status=$s)"; sleep 0.5; break ;;
        *) log "status=$s; abort (no /clear)"; disarm; exit 1 ;;
      esac
    fi
    if (( i++ % 10 == 0 )); then   # hc every ~2s; the Stop signal every 0.2s
      s=$(status)
      case "$s" in
        working) ;;
        blocked) fresh || { log "status=$s; abort (no /clear)"; disarm; exit 1; } ;;
        idle|done) sleep 2; [[ $(status) == "$s" ]] && { log "reply ended (status=$s)"; break; } ;;
        *) log "status=$s; abort (no /clear)"; disarm; exit 1 ;;
      esac
    fi
    sleep 0.2
  done

  ours || { log "superseded by a newer handoff; stop"; exit 0; }
  if [[ ! -s "$F" ]] || ! grep -q '^[[:space:]]*# ' "$F"; then
    log "note missing/empty/no heading; abort (no /clear)"; disarm; exit 1
  fi

  # 2. /clear. The SessionStart hook loads the note and touches <key>.loaded.
  #    Re-arm so a long wait (background agents) does not make the hook treat it as stale.
  #    Lazy agents in load mode consume it with the user's next prompt: keep it for a day.
  if (( lazy )) && [[ $mode == load ]]; then arm 1440; else arm 120; fi
  # hc send waits (~5s) for a turn to start, and /clear never starts one: don't block on it.
  hc send "$T" "/clear" >/dev/null 2>&1 &
  local sender=$!
  log "sent /clear"

  if (( lazy )); then
    # The hook fires with the next prompt. Make sure /clear went through first.
    for i in $(seq 1 100); do kill -0 "$sender" 2>/dev/null || break; sleep 0.1; done
    if ! kill -0 "$sender" 2>/dev/null && ! wait "$sender"; then
      log "send /clear failed"; disarm; exit 1
    fi
    [[ $mode == auto ]] || { log "load mode; the note loads with the next prompt; done"; exit 0; }
    sleep "${HERDR_HANDOFF_SETTLE:-0.5}"
  else
    # 3. Wait for the hook's signal (do not rely on hc wait: /clear may not report a turn end).
    for i in $(seq 1 600); do
      [[ -e "$STATE/$key.loaded" ]] && break
      if (( i % 10 == 0 )) && ! kill -0 "$sender" 2>/dev/null && ! wait "$sender"; then
        log "send /clear failed"; disarm; exit 1
      fi
      sleep 0.1
    done
    if [[ ! -e "$STATE/$key.loaded" ]]; then
      log "note was not loaded within 60s (hook missing?); stop"; disarm; exit 1
    fi
    rm -f "$STATE/$key.loaded"
    log "note loaded"
    [[ $mode == auto ]] || { log "load mode; done"; exit 0; }
    # 4. Let the input box settle, then send the auto prompt.
    sleep "${HERDR_HANDOFF_SETTLE:-0.5}"
  fi

  s=$(status)
  case "$s" in idle|done) ;; *) log "status=$s after /clear; auto prompt not sent"; disarm; exit 1 ;; esac
  local prompt="${HERDR_HANDOFF_AUTO_PROMPT:-$DEFAULT_AUTO_PROMPT}"
  hc send "$T" "${prompt//\{file\}/$F}" >/dev/null 2>&1 || { log "send auto prompt failed"; exit 1; }
  log "sent auto prompt"
  if (( lazy )); then
    for i in $(seq 1 300); do [[ -e "$STATE/$key.loaded" ]] && break; sleep 0.2; done
    if [[ -e "$STATE/$key.loaded" ]]; then rm -f "$STATE/$key.loaded"; log "note loaded; done"
    else log "note was not loaded with the auto prompt (hook missing?)"; disarm; exit 1; fi
  fi
}

# Stop hook: the main reply has ended. Signal the driver if a reload is armed here.
cmd_stop() {
  cat >/dev/null
  local key; key=$(slot_key)
  [[ -f "$STATE/$key.pending" ]] && touch "$STATE/$key.stopped"
  exit 0
}

# SessionStart hook (matcher "clear"). Reads the hook JSON on stdin; prints hook JSON.
cmd_session_start() {
  cat >/dev/null  # hook input is not needed; the slot comes from the environment
  local key; key=$(slot_key)
  LOGTAG=$key
  local p="$STATE/$key.pending"
  [[ -f "$p" ]] || exit 0
  local mode file ttl app me
  { read -r mode; read -r file; read -r ttl; read -r app; } <"$p"
  [[ $ttl =~ ^[0-9]+$ ]] || ttl=120
  # Ignore stale arms (default: older than 2 hours).
  if [[ -n $(find "$p" -mmin "+$ttl" 2>/dev/null) ]]; then rm -f "$p"; exit 0; fi
  # An arm made for another agent (e.g. it was quit and another started in this terminal).
  me=$(hook_app)
  if [[ -n $app && -n $me && $app != "$me" ]]; then
    log "hook: arm for $app ignored by $me; dropped"; rm -f "$p"; exit 0
  fi
  rm -f "$p"
  [[ -s "$file" ]] || { log "hook: note missing: $file"; exit 0; }
  command -v jq >/dev/null || { log "hook: jq not found"; exit 0; }

  local how
  if [[ $mode == auto ]]; then
    how='続行の指示（引継書からゴールを設定して実行）が届いたら、それに従ってください。届くまでは作業を始めないでください。'
  else
    how='引継書を読み込んだだけの状態です。ユーザーの指示に従い、指示があるまで作業を始めないでください。'
  fi
  local ctx
  ctx=$(printf '前の会話からの引継書（%s）を読み込みました。%s\n\n<handoff path="%s">\n%s\n</handoff>' \
        "$file" "$how" "$file" "$(cat "$file")")
  jq -n --arg ctx "$ctx" --arg msg "引継書を読み込みました: $file" \
    '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  touch "$STATE/$key.loaded"
  log "hook: loaded mode=$mode file=$file"
}

case "${1:-}" in
  path)  shift; cmd_path "$@" ;;
  start) shift; cmd_start "$@" ;;
  run)   shift; cmd_run "$@" ;;
  session-start) shift; cmd_session_start "$@" ;;
  stop)  shift; cmd_stop "$@" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
