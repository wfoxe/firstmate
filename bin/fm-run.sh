#!/usr/bin/env bash
# Run firstmate in a restart loop. A firstmate self-rotation is:
#   /stow
#   exit the harness
# This wrapper then starts a fresh harness session in the same firstmate home.
#
# Usage:
#   bin/fm-run.sh [--harness claude|codex|opencode|pi|grok] [-- <command...>]
#   FM_RUN_COMMAND='claude --model opus' bin/fm-run.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

HARNESS=${FM_RUN_HARNESS:-}
ONCE=0
CMD=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      shift
      [ $# -gt 0 ] || { echo "fm-run: --harness requires a value" >&2; exit 2; }
      HARNESS=$1
      ;;
    --harness=*)
      HARNESS=${1#--harness=}
      ;;
    --once)
      ONCE=1
      ;;
    --)
      shift
      CMD=("$@")
      break
      ;;
    *)
      echo "usage: fm-run.sh [--harness <name>] [--once] [-- <command...>]" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "${#CMD[@]}" -eq 0 ] && [ -n "${FM_RUN_COMMAND:-}" ]; then
  # Deliberately use a shell for this escape hatch so operators can pass normal
  # command strings with flags. The default path below avoids eval.
  CMD=(bash -lc "$FM_RUN_COMMAND")
fi

if [ "${#CMD[@]}" -eq 0 ]; then
  if [ -z "$HARNESS" ]; then
    HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
    [ -n "$HARNESS" ] && [ "$HARNESS" != unknown ] || HARNESS=claude
  fi
  case "$HARNESS" in
    claude) CMD=(claude) ;;
    codex) CMD=(codex) ;;
    opencode) CMD=(opencode) ;;
    pi) CMD=(pi) ;;
    grok) CMD=(grok) ;;
    *) echo "fm-run: unknown harness '$HARNESS'; pass -- <command...>" >&2; exit 2 ;;
  esac
fi

MIN_RUNTIME=${FM_RUN_MIN_RUNTIME_SECS:-30}
BACKOFF=${FM_RUN_BACKOFF_SECS:-10}
BACKOFF_MAX=${FM_RUN_BACKOFF_MAX_SECS:-300}
case "$MIN_RUNTIME" in ''|*[!0-9]*) MIN_RUNTIME=30 ;; esac
case "$BACKOFF" in ''|*[!0-9]*) BACKOFF=10 ;; esac
case "$BACKOFF_MAX" in ''|*[!0-9]*) BACKOFF_MAX=300 ;; esac

trap 'exit 130' INT
trap 'exit 143' TERM

while :; do
  start=$(date +%s)
  set +e
  (
    cd "$FM_HOME"
    export FM_HOME
    "${CMD[@]}"
  )
  rc=$?
  set -e
  [ "$ONCE" = 1 ] && exit "$rc"
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -lt "$MIN_RUNTIME" ]; then
    echo "fm-run: session exited after ${elapsed}s (code $rc); backing off ${BACKOFF}s before relaunch" >&2
    sleep "$BACKOFF"
    BACKOFF=$(( BACKOFF * 2 ))
    [ "$BACKOFF" -le "$BACKOFF_MAX" ] || BACKOFF=$BACKOFF_MAX
  else
    BACKOFF=${FM_RUN_BACKOFF_SECS:-10}
    case "$BACKOFF" in ''|*[!0-9]*) BACKOFF=10 ;; esac
  fi
done
