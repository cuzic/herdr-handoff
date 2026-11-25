#!/usr/bin/env bash
# hc-handoff.sh — handoff → /clear → resume for Claude Code in a herdr-core (hc) terminal.
#
#   hc-handoff.sh path                 print a fresh handoff file path (creates the dir)
#   hc-handoff.sh start <file>         detach the driver for $HC_TERMINAL_ID; prints "launched"
#   hc-handoff.sh run <terminal> <file>  the driver itself (normally started by `start`)
#
# The driver waits for the terminal's current turn to end, checks the handoff file,
# sends /clear, waits again, then sends a resume prompt naming the file.
# It never sends /clear if the terminal is blocked, errored, or the file is missing.
#
# Environment:
#   HERDR_HANDOFF_DIR   where handoff files go (default: ~/handoffs)
#   HERDR_HANDOFF_PROMPT  resume prompt; "{file}" is replaced with the path
set -uo pipefail

DIR="${HERDR_HANDOFF_DIR:-$HOME/handoffs}"
LOG="$DIR/.hc-handoff.log"
DEFAULT_PROMPT='引継書 {file} を読んで、前の会話の作業を継続してください。まず実際のファイル・git・プロセスの状態を確認し、引継書の「次の手順」から再開してください。確認が必要な判断がある場合だけ質問してください。'

die() { echo "hc-handoff: $*" >&2; exit 1; }

cmd_path() {
  mkdir -p "$DIR" || die "cannot create $DIR"
  printf '%s/%s-%s.md\n' "$DIR" "$(date +%Y%m%d-%H%M%S)" "$(basename "$PWD")"
}

cmd_start() {
  local f="${1:?usage: start <file>}"
  command -v hc >/dev/null || die "hc (herdr-core) not found"
  command -v jq >/dev/null || die "jq not found"
  [[ -n "${HC_TERMINAL_ID:-}" ]] || die "not inside a herdr-core terminal (HC_TERMINAL_ID unset)"
  [[ -s "$f" ]] || die "handoff file is missing or empty: $f"
  mkdir -p "$DIR"
  setsid -f "$0" run "$HC_TERMINAL_ID" "$f" >/dev/null 2>&1 </dev/null || die "failed to detach"
  echo launched
}

cmd_run() {
  local T="${1:?terminal}" F="${2:?file}"
  mkdir -p "$DIR"
  log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$T" "$*" >>"$LOG"; }

  # Talk to hc as an outside controller, not as a child of the terminal we drive.
  unset HC_TERMINAL_ID HC_SCOPE

  exec 9>"$DIR/.hc-handoff.$T.lock"
  flock -n 9 || { log "already running; abort"; exit 1; }

  status() { hc get "$T" --json 2>/dev/null | jq -r '.status.state // "none"'; }

  # Wait until the turn ends. working → keep waiting; idle/done (stable) → go; else abort.
  wait_turn_end() {
    local deadline=$(( $(date +%s) + $1 )) s
    while (( $(date +%s) < deadline )); do
      hc wait "$T" --timeout 300 >/dev/null 2>&1
      s=$(status)
      case "$s" in
        working) continue ;;
        idle|done) sleep 2; [[ $(status) == "$s" ]] && return 0 ;;
        *) log "status=$s; abort (no /clear)"; return 1 ;;
      esac
    done
    log "timeout waiting for turn end; abort"; return 1
  }

  log "start file=$F"
  wait_turn_end 3600 || exit 1

  if [[ ! -s "$F" ]] || ! grep -q '^# ' "$F"; then
    log "handoff file missing/empty/no heading; abort (no /clear)"; exit 1
  fi

  hc send "$T" "/clear" >/dev/null 2>&1 || { log "send /clear failed"; exit 1; }
  log "sent /clear"
  sleep 3
  wait_turn_end 120 || exit 1

  local prompt="${HERDR_HANDOFF_PROMPT:-$DEFAULT_PROMPT}"
  hc send "$T" "${prompt//\{file\}/$F}" >/dev/null 2>&1 || { log "send resume failed"; exit 1; }
  log "sent resume; done"
}

case "${1:-}" in
  path)  shift; cmd_path "$@" ;;
  start) shift; cmd_start "$@" ;;
  run)   shift; cmd_run "$@" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
