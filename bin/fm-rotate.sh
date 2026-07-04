#!/usr/bin/env bash
# Soft-rotate one supervised agent session after its handoff/stow artifact is
# committed. The worktree and branch stay exactly where they are; only the
# harness process in the recorded endpoint is exited and relaunched.
#
# Usage: fm-rotate.sh <task-id> [--handoff <path>]
# If no committed handoff is found, the foreground-safe default sends the crew a
# handoff request and exits 3. Set FM_ROTATE_WAIT_SECS to a positive value only
# when this script is running as its own supervised background task.
# If a prior attempt already exited the harness and left the endpoint at a
# verified shell in the task worktree, re-running this script relaunches there.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  echo "usage: fm-rotate.sh <task-id> [--handoff <path>]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
ID=$1
shift
HANDOFF_ARG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --handoff)
      shift
      [ $# -gt 0 ] || usage
      HANDOFF_ARG=$1
      ;;
    --handoff=*)
      HANDOFF_ARG=${1#--handoff=}
      [ -n "$HANDOFF_ARG" ] || usage
      ;;
    *)
      usage
      ;;
  esac
  shift
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

meta_value() { fm_meta_get "$META" "$1"; }

WT=$(meta_value worktree)
HARNESS=$(meta_value harness)
KIND=$(meta_value kind)
MODEL=$(meta_value model)
EFFORT=$(meta_value effort)
TASK_TMP=$(meta_value tasktmp)
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
[ -n "$KIND" ] || KIND=ship
[ -n "$MODEL" ] || MODEL=default
[ -n "$EFFORT" ] || EFFORT=default
[ -n "$TASK_TMP" ] || TASK_TMP="/tmp/fm-$ID"
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: worktree for $ID is missing: ${WT:-<empty>}" >&2; exit 1; }
[ -n "$TARGET" ] || { echo "error: no backend target recorded for $ID" >&2; exit 1; }

preflight_rotation_support() {
  local status
  if [ "$KIND" = secondmate ]; then
    echo "error: fm-rotate does not yet support kind=secondmate; rotate the secondmate from inside its own home with /stow, then relaunch it through the secondmate lifecycle" >&2
    return 1
  fi
  if [ "$HARNESS" = grok ] && [ "$BACKEND" = orca ]; then
    echo "error: rotation for harness=grok on backend=orca is unsupported: Grok's verified exit chord is Ctrl-Q, but the Orca adapter does not support that key yet" >&2
    return 1
  fi
  set +e
  fm_backend_shell_ready "$BACKEND" "$TARGET" "$WT" "$EXPECTED_LABEL" >/dev/null 2>&1
  status=$?
  set -e
  if [ "$status" -eq 2 ]; then
    echo "error: rotation for backend '$BACKEND' is unsupported: shell readiness cannot be verified before relaunch" >&2
    return 1
  fi
}

preflight_rotation_support || exit 1

worktree_dirty_line() {
  git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

path_to_worktree_rel() {  # <path>
  local p=$1 abs wt_abs
  wt_abs=$(cd "$WT" && pwd -P)
  case "$p" in
    /*) abs=$p ;;
    *) abs="$WT/$p" ;;
  esac
  [ -e "$abs" ] || return 1
  abs=$(cd "$(dirname "$abs")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$abs")")
  case "$abs" in
    "$wt_abs"/*) printf '%s\n' "${abs#"$wt_abs"/}" ;;
    *) return 1 ;;
  esac
}

handoff_is_committed() {  # <relpath>
  local rel=$1
  [ -n "$rel" ] || return 1
  git -C "$WT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "HEAD:$rel" 2>/dev/null
}

date_to_epoch() {  # <iso-date>
  local date_value=$1
  [ -n "$date_value" ] || return 1
  if date -u -d "$date_value" '+%s' >/dev/null 2>&1; then
    date -u -d "$date_value" '+%s'
    return 0
  fi
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$date_value" '+%s' 2>/dev/null
}

last_rotation_epoch() {
  local rotation_at
  rotation_at=$(meta_value rotation_at)
  if [ -n "$rotation_at" ]; then
    date_to_epoch "$rotation_at" || return 1
    return 0
  fi
  [ -z "$(meta_value rotation_handoff)" ] || return 1
  return 2
}

handoff_is_fresh() {  # <relpath>
  local rel=$1 cutoff status handoff_epoch
  set +e
  cutoff=$(last_rotation_epoch)
  status=$?
  set -e
  [ "$status" -eq 2 ] && return 0
  [ "$status" -eq 0 ] || return 1
  handoff_epoch=$(git -C "$WT" log -1 --format=%ct -- "$rel" 2>/dev/null) || return 1
  [ -n "$handoff_epoch" ] || return 1
  [ "$handoff_epoch" -gt "$cutoff" ]
}

handoff_matches_task() {  # <relpath>
  local rel=$1
  case "$rel" in
    *"$ID"*) return 0 ;;
  esac
  git -C "$WT" show "HEAD:$rel" 2>/dev/null \
    | grep -Ei "(task|rotation|handoff|stow)[[:space:]_-]*(id|for|task)?[[:space:]:#-]*(fm-)?${ID}([^[:alnum:]_-]|$)" >/dev/null
}

detect_handoff_rel() {
  local rel
  if [ -n "$HANDOFF_ARG" ]; then
    rel=$(path_to_worktree_rel "$HANDOFF_ARG") || {
      echo "error: --handoff must name an existing file inside the task worktree" >&2
      return 1
    }
    handoff_is_committed "$rel" || {
      echo "error: --handoff $rel is not a committed tracked file" >&2
      return 1
    }
    handoff_is_fresh "$rel" || {
      echo "error: --handoff $rel is not newer than the previous rotation recorded in $META" >&2
      return 1
    }
    printf '%s\n' "$rel"
    return 0
  fi
  while IFS= read -r rel; do
    case "$rel" in
      *.md|*.markdown) ;;
      *) continue ;;
    esac
    case "$rel" in
      *handoff*|*Handoff*|*HANDOFF*|*stow*|*Stow*|*STOW*) ;;
      *) continue ;;
    esac
    handoff_is_committed "$rel" || continue
    handoff_is_fresh "$rel" || continue
    handoff_matches_task "$rel" || continue
    printf '%s\n' "$rel"
    return 0
  done < <(git -C "$WT" ls-files)
  return 1
}

send_text_submit() {  # <text> [strict-empty]
  local text=$1 strict_empty=${2:-0} verdict
  verdict=$(submit_text_verdict "$text")
  case "$verdict" in
    empty) return 0 ;;
    pending|send-failed)
      if [ "$strict_empty" = 1 ]; then
        echo "error: text submission to $TARGET during rotation was not confirmed empty (verdict=$verdict)" >&2
        return 1
      fi
      echo "error: text not submitted to $TARGET during rotation (verdict=$verdict)" >&2
      return 1
      ;;
    *)
      if [ "$strict_empty" = 1 ]; then
        echo "error: text submission to $TARGET during rotation was not confirmed empty (verdict=$verdict)" >&2
        return 1
      fi
      ;;
  esac
}

submit_text_verdict() {  # <text> -> empty|pending|unknown|send-failed
  local text=$1 settle=0.3 verdict
  case "$text" in /*|\$*) settle=1.2 ;; esac
  if ! verdict=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$text" "${FM_ROTATE_SEND_RETRIES:-3}" "${FM_ROTATE_SEND_SLEEP:-0.4}" "$settle" "$EXPECTED_LABEL"); then
    verdict=send-failed
  fi
  printf '%s' "$verdict"
}

shell_ready_now() {
  fm_backend_shell_ready "$BACKEND" "$TARGET" "$WT" "$EXPECTED_LABEL" >/dev/null 2>&1
}

wait_for_shell_ready_quiet() {  # <timeout> <poll>
  local timeout=$1 poll=$2 deadline now status
  case "$timeout" in ''|*[!0-9]*) timeout=3 ;; esac
  case "$poll" in ''|*[!0-9]*) poll=1 ;; esac
  [ "$poll" -gt 0 ] || poll=1
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    set +e
    shell_ready_now
    status=$?
    set -e
    [ "$status" -eq 0 ] && return 0
    [ "$status" -eq 2 ] && return 2
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && return 1
    sleep "$poll"
  done
}

submit_exit_command() {  # <command>
  local text=$1 verdict ack_timeout=${FM_ROTATE_EXIT_ACK_TIMEOUT:-3} ack_poll=${FM_ROTATE_EXIT_ACK_POLL_SECS:-1}
  verdict=$(submit_text_verdict "$text")
  case "$verdict" in
    empty) return 0 ;;
    pending|unknown)
      if wait_for_shell_ready_quiet "$ack_timeout" "$ack_poll"; then
        return 0
      fi
      echo "error: exit command for $ID was not acknowledged by an empty composer or verified shell (verdict=$verdict)" >&2
      return 1
      ;;
    send-failed)
      echo "error: exit command for $ID could not be submitted (verdict=$verdict)" >&2
      return 1
      ;;
    *)
      if wait_for_shell_ready_quiet "$ack_timeout" "$ack_poll"; then
        return 0
      fi
      echo "error: exit command for $ID returned an unknown submit verdict and no verified shell (verdict=$verdict)" >&2
      return 1
      ;;
  esac
}

request_handoff() {
  local rel="docs/firstmate-handoff-$ID.md"
  case "$KIND" in scout) rel="docs/firstmate-scout-handoff-$ID.md" ;; esac
  send_text_submit "Context rotation is due. Before continuing, stow the task state into a committed handoff doc (suggested path: $rel): current objective, branch, changed files, decisions, validation status, and next steps. Commit the handoff with your current work, report working or done, and then STOP at the turn boundary. Do not start new feature work after the handoff is committed."
  echo "rotation requested handoff for $ID"
}

crew_busy_now() {
  local bs capture
  bs=$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null)
  [ "$bs" = busy ] && return 0
  capture=$(fm_backend_capture "$BACKEND" "$TARGET" "${FM_ROTATE_BUSY_CAPTURE_LINES:-80}" "$EXPECTED_LABEL" 2>/dev/null) || return 2
  printf '%s' "$capture" | fm_capture_has_busy_signature && return 0
  return 1
}

rotation_boundary_ready() {  # [quiet]
  local quiet=${1:-0} busy_status composer
  if crew_is_provably_working "$ID"; then
    [ "$quiet" = 1 ] || echo "REFUSED: $ID is still provably working; rotate only at a turn boundary." >&2
    return 1
  fi
  set +e
  crew_busy_now
  busy_status=$?
  set -e
  case "$busy_status" in
    0)
      [ "$quiet" = 1 ] || echo "REFUSED: $ID still shows a harness busy signature in a fresh pane capture; rotate only at a turn boundary." >&2
      return 1
      ;;
    2)
      [ "$quiet" = 1 ] || echo "REFUSED: could not verify $ID pane is idle immediately before exit; refusing to risk a mid-turn rotation." >&2
      return 1
      ;;
  esac
  composer=$(fm_backend_composer_state "$BACKEND" "$TARGET" "$EXPECTED_LABEL" 2>/dev/null || printf unknown)
  if [ "$composer" != empty ]; then
    if shell_ready_now; then
      return 0
    fi
    [ "$quiet" = 1 ] || echo "REFUSED: $ID composer is not confirmed empty (state=$composer); refusing to send the exit command." >&2
    return 1
  fi
  return 0
}

wait_for_handoff() {
  local wait_secs=${FM_ROTATE_WAIT_SECS:-0} poll=${FM_ROTATE_WAIT_POLL_SECS:-10}
  local deadline now dirty_after
  case "$wait_secs" in ''|*[!0-9]*) wait_secs=0 ;; esac
  case "$poll" in ''|*[!0-9]*) poll=10 ;; esac
  [ "$poll" -gt 0 ] || poll=1
  [ "$wait_secs" -gt 0 ] || return 1
  deadline=$(( $(date +%s) + wait_secs ))
  echo "waiting up to ${wait_secs}s for $ID to commit a handoff and return to an idle boundary..."
  while :; do
    HANDOFF_REL=$(detect_handoff_rel 2>/dev/null || true)
    if [ -n "$HANDOFF_REL" ]; then
      dirty_after=$(worktree_dirty_line)
      if [ -z "$dirty_after" ] && rotation_boundary_ready 1; then
        return 0
      fi
    fi
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && return 1
    sleep "$poll"
  done
}

if ! HANDOFF_REL=$(detect_handoff_rel); then
  [ -z "$HANDOFF_ARG" ] || exit 1
  HANDOFF_REL=
fi
if [ -z "$HANDOFF_REL" ]; then
  request_handoff
  if ! wait_for_handoff; then
    echo "rotation pending handoff for $ID; re-run bin/fm-rotate.sh $ID after the committed handoff exists"
    exit 3
  fi
fi
HANDOFF_ABS="$WT/$HANDOFF_REL"

dirty=$(worktree_dirty_line)
if [ -n "$dirty" ]; then
  echo "REFUSED: worktree $WT has uncommitted changes after handoff wait." >&2
  exit 1
fi
rotation_boundary_ready || exit 1

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok) printf -- '--model %s ' "$(shell_quote "$model")" ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude) case "$effort" in low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;; esac ;;
    codex) case "$effort" in low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;; esac ;;
    grok) case "$effort" in low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;; esac ;;
    pi) case "$effort" in low|medium|high|xhigh) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;; esac ;;
  esac
}

write_pi_extension_if_needed() {
  [ "$HARNESS" = pi ] || return 0
  [ "$KIND" != secondmate ] || return 0
  [ -f "$STATE/$ID.pi-ext.ts" ] && return 0
  TURNEND="$STATE/$ID.turn-ended"
  cat > "$STATE/$ID.pi-ext.ts" <<EOF
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
}

write_continuation_prompt() {
  local dir="$DATA/$ID" branch brief data_abs
  mkdir -p "$dir"
  branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD)
  data_abs=$(cd "$dir" && pwd -P)
  brief="$data_abs/brief.md"
  PROMPT="$dir/rotation-prompt.md"
  cat > "$PROMPT" <<EOF
# Continue Task After Context Rotation

You are continuing the same firstmate task after a soft context rotation.

- Stay in this exact worktree: $WT
- Stay on the existing branch: $branch
- Read AGENTS.md and the original task brief before making changes: $brief
- Read the committed handoff/stow artifact: $HANDOFF_REL
- Inspect git status and recent commits, then continue from the handoff.
- Do not create a new worktree or duplicate the branch.
- Report status using the original task status contract.
EOF
}

launch_template() {
  local kind=${1:-ship}
  case "$HARNESS" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __PROMPT__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __PROMPT__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __PROMPT__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __PROMPT__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__"$(cat __PROMPT__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __PROMPT__)"'
      fi
      ;;
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __PROMPT__)"' ;;
    *) echo "error: no rotation launch template for harness '$HARNESS'" >&2; return 1 ;;
  esac
}

exit_agent() {
  case "$HARNESS" in
    claude|opencode) submit_exit_command "/exit" || { cleanup_pending_exit_text; return 1; } ;;
    codex|pi) submit_exit_command "/quit" || { cleanup_pending_exit_text; return 1; } ;;
    grok)
      fm_backend_send_key "$BACKEND" "$TARGET" C-q "$EXPECTED_LABEL"
      sleep 0.2
      fm_backend_send_key "$BACKEND" "$TARGET" C-q "$EXPECTED_LABEL"
      ;;
    *) echo "error: no verified exit command for harness '$HARNESS'" >&2; return 1 ;;
  esac
}

cleanup_pending_exit_text() {
  fm_backend_send_key "$BACKEND" "$TARGET" Escape "$EXPECTED_LABEL" >/dev/null 2>&1 || true
  sleep 0.1
  fm_backend_send_key "$BACKEND" "$TARGET" C-u "$EXPECTED_LABEL" >/dev/null 2>&1 || true
}

wait_for_shell_ready() {
  local timeout=${FM_ROTATE_EXIT_TIMEOUT:-${FM_ROTATE_EXIT_SETTLE:-30}} poll=${FM_ROTATE_EXIT_POLL_SECS:-1}
  local deadline now status
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  case "$poll" in ''|*[!0-9]*) poll=1 ;; esac
  [ "$poll" -gt 0 ] || poll=1
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    set +e
    fm_backend_shell_ready "$BACKEND" "$TARGET" "$WT" "$EXPECTED_LABEL"
    status=$?
    set -e
    [ "$status" -eq 0 ] && return 0
    if [ "$status" -eq 2 ]; then
      echo "error: backend '$BACKEND' cannot verify shell readiness after harness exit; refusing to relaunch into an unverified endpoint" >&2
      return 1
    fi
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && break
    sleep "$poll"
  done
  echo "error: $TARGET did not return to a verified shell in $WT within ${timeout}s after harness exit; refusing to send relaunch commands" >&2
  return 1
}

write_pi_extension_if_needed
write_continuation_prompt

if ! shell_ready_now; then
  exit_agent
  wait_for_shell_ready
fi

mkdir -p "$TASK_TMP/gotmp"
fm_backend_send_text_line "$BACKEND" "$TARGET" "cd $(shell_quote "$WT")" "$EXPECTED_LABEL"
sleep 0.2
fm_backend_send_text_line "$BACKEND" "$TARGET" "export GOTMPDIR=$TASK_TMP/gotmp" "$EXPECTED_LABEL"
sleep 0.2

TURNEND="$STATE/$ID.turn-ended"
LAUNCH=$(launch_template "$KIND")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__PROMPT__/$(shell_quote "$PROMPT")}
LAUNCH=${LAUNCH//__TURNEND__/$(shell_quote "$TURNEND")}
LAUNCH=${LAUNCH//__PIEXT__/$(shell_quote "$STATE/$ID.pi-ext.ts")}
if [ "$KIND" = secondmate ]; then
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$(shell_quote "$WT") $LAUNCH"
fi

fm_backend_send_literal "$BACKEND" "$TARGET" "$LAUNCH" "$EXPECTED_LABEL"
sleep 0.2
fm_backend_send_key "$BACKEND" "$TARGET" Enter "$EXPECTED_LABEL"

wait_for_harness_started() {
  local timeout=${FM_ROTATE_LAUNCH_TIMEOUT:-20} poll=${FM_ROTATE_LAUNCH_POLL_SECS:-1}
  local deadline status now
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  case "$poll" in ''|*[!0-9]*) poll=1 ;; esac
  [ "$poll" -gt 0 ] || poll=1
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    set +e
    fm_backend_shell_ready "$BACKEND" "$TARGET" "$WT" "$EXPECTED_LABEL" >/dev/null 2>&1
    status=$?
    set -e
    case "$status" in
      0) ;;
      2)
        echo "error: backend '$BACKEND' stopped supporting shell readiness during relaunch verification" >&2
        return 1
        ;;
      *) return 0 ;;
    esac
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && break
    sleep "$poll"
  done
  echo "error: relaunch command for $ID did not leave the verified shell within ${timeout}s; not recording rotation success" >&2
  return 1
}

wait_for_harness_started

{
  echo "rotation_handoff=$HANDOFF_ABS"
  echo "rotation_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >> "$META"

echo "rotated $ID on $BACKEND target $TARGET using handoff $HANDOFF_REL"
