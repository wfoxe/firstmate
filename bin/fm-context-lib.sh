#!/usr/bin/env bash
# Shared context-fullness telemetry for supervised agent panes.
#
# This library is intentionally conservative: unsupported or unparseable pane
# text returns no percentage. A missing reading must never become a false
# rotation signal.

FM_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_CONTEXT_DEFAULT_ROOT="$(cd "$FM_CONTEXT_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_CONTEXT_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"

if ! declare -F fm_backend_capture >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$FM_CONTEXT_LIB_DIR/fm-backend.sh"
fi

fm_context_threshold() {
  local t=${FM_ROTATE_THRESHOLD:-70}
  case "$t" in
    ''|*[!0-9]*) t=70 ;;
  esac
  [ "$t" -lt 0 ] && t=0
  [ "$t" -gt 100 ] && t=100
  printf '%s' "$t"
}

fm_context_parse_claude_fullness() {
  awk '
    /[█░]/ && /%[[:space:]]*$/ && (index($0, "│") || index($0, "|")) {
      line = $0
      sub(/%[[:space:]]*$/, "", line)
      sub(/.*[^0-9]/, "", line)
      if (line ~ /^[0-9]+$/ && (line + 0) <= 100) pct = line
    }
    END {
      if (pct != "") print pct
    }
  '
}

fm_context_parse_fullness_for_harness() {  # <harness>; reads capture text on stdin
  local harness=$1
  shift || true
  case "$harness" in
    claude|claude-*)
      fm_context_parse_claude_fullness
      ;;
    # Codex context telemetry is deliberately unsupported until a real footer
    # format is verified for the installed TUI. Some versions are reported to
    # show "NN% context left", which is remaining context rather than fullness,
    # but guessing here would risk false rotations.
    codex|codex-*)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

fm_context_percent_from_meta() {  # <meta-file> [state-dir]
  local meta=$1 state=${2:-$STATE} harness backend target expected capture pct id
  [ -f "$meta" ] || return 1
  harness=$(fm_meta_get "$meta" harness 2>/dev/null || true)
  [ -n "$harness" ] || return 1
  case "$harness" in
    claude|claude-*) ;;
    *) return 1 ;;
  esac
  backend=$(fm_backend_of_meta "$meta" 2>/dev/null || true)
  [ -n "$backend" ] || backend=tmux
  target=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  id=$(basename "$meta")
  id=${id%.meta}
  expected="fm-$id"
  capture=$(fm_backend_capture "$backend" "$target" "${FM_CONTEXT_CAPTURE_LINES:-12}" "$expected" 2>/dev/null) || return 1
  pct=$(printf '%s\n' "$capture" | fm_context_parse_fullness_for_harness "$harness" 2>/dev/null || true)
  case "$pct" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pct" -le 100 ] || return 1
  printf '%s' "$pct"
}

fm_context_percent_for_task() {  # <id> [state-dir]
  local id=$1 state=${2:-$STATE}
  [ -n "$id" ] || return 1
  fm_context_percent_from_meta "$state/$id.meta" "$state"
}
