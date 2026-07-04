#!/usr/bin/env bash
# Soft-rotate one supervised agent session after its handoff/stow artifact is
# committed. The worktree and branch stay exactly where they are; only the
# harness process in the recorded endpoint is exited and relaunched.
#
# Usage: fm-rotate.sh <task-id> [--handoff <path>]
# If no committed handoff is found, the script sends the crew a handoff request,
# waits for a committed handoff and a non-busy boundary, then restarts. Set
# FM_ROTATE_WAIT_SECS=0 to request the handoff and return immediately.
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

worktree_dirty_line() {
  git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true
}

dirty=$(worktree_dirty_line)
if [ -n "$dirty" ]; then
  echo "REFUSED: worktree $WT has uncommitted changes." >&2
  echo "Commit or discard them before rotating; a rotation must not strand un-stowed work." >&2
  exit 1
fi

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

detect_handoff_rel() {
  local rel best=""
  if [ -n "$HANDOFF_ARG" ]; then
    rel=$(path_to_worktree_rel "$HANDOFF_ARG") || {
      echo "error: --handoff must name an existing file inside the task worktree" >&2
      return 1
    }
    handoff_is_committed "$rel" || {
      echo "error: --handoff $rel is not a committed tracked file" >&2
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
    case "$rel" in
      *"$ID"*) printf '%s\n' "$rel"; return 0 ;;
    esac
    [ -n "$best" ] || best=$rel
  done < <(git -C "$WT" ls-files)
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

send_text_submit() {  # <text>
  local text=$1 settle=0.3 verdict
  case "$text" in /*|\$*) settle=1.2 ;; esac
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$text" "${FM_ROTATE_SEND_RETRIES:-3}" "${FM_ROTATE_SEND_SLEEP:-0.4}" "$settle" "$EXPECTED_LABEL")
  case "$verdict" in
    pending|send-failed)
      echo "error: text not submitted to $TARGET during rotation (verdict=$verdict)" >&2
      return 1
      ;;
  esac
}

request_handoff() {
  local rel="docs/firstmate-handoff-$ID.md"
  case "$KIND" in scout) rel="docs/firstmate-scout-handoff-$ID.md" ;; esac
  send_text_submit "Context rotation is due. Before continuing, stow the task state into a committed handoff doc (suggested path: $rel): current objective, branch, changed files, decisions, validation status, and next steps. Commit the handoff with your current work, then report working or done. Do not start new feature work until the handoff is committed."
  echo "rotation requested handoff for $ID"
}

wait_for_handoff() {
  local wait_secs=${FM_ROTATE_WAIT_SECS:-900} poll=${FM_ROTATE_WAIT_POLL_SECS:-10}
  local deadline now dirty_after
  case "$wait_secs" in ''|*[!0-9]*) wait_secs=900 ;; esac
  case "$poll" in ''|*[!0-9]*) poll=10 ;; esac
  [ "$poll" -gt 0 ] || poll=1
  [ "$wait_secs" -gt 0 ] || return 1
  deadline=$(( $(date +%s) + wait_secs ))
  echo "waiting up to ${wait_secs}s for $ID to commit a handoff and return to an idle boundary..."
  while :; do
    HANDOFF_REL=$(detect_handoff_rel 2>/dev/null || true)
    if [ -n "$HANDOFF_REL" ]; then
      dirty_after=$(worktree_dirty_line)
      if [ -z "$dirty_after" ] && ! crew_is_provably_working "$ID"; then
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
if crew_is_provably_working "$ID"; then
  echo "REFUSED: $ID is still provably working; rotate only at a turn boundary." >&2
  exit 1
fi

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
  local dir="$DATA/$ID" branch
  mkdir -p "$dir"
  branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD)
  PROMPT="$dir/rotation-prompt.md"
  cat > "$PROMPT" <<EOF
# Continue Task After Context Rotation

You are continuing the same firstmate task after a soft context rotation.

- Stay in this exact worktree: $WT
- Stay on the existing branch: $branch
- Read AGENTS.md and the original task brief before making changes.
- Read the committed handoff/stow artifact: $HANDOFF_REL
- Inspect git status and recent commits, then continue from the handoff.
- Do not create a new worktree or duplicate the branch.
- Report status using the original task status contract.
EOF
}

launch_template() {
  case "$HARNESS" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __PROMPT__)"' ;;
    codex) printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __PROMPT__)"' ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __PROMPT__)"' ;;
    pi) printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __PROMPT__)"' ;;
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __PROMPT__)"' ;;
    *) echo "error: no rotation launch template for harness '$HARNESS'" >&2; return 1 ;;
  esac
}

exit_agent() {
  case "$HARNESS" in
    claude|opencode) send_text_submit "/exit" ;;
    codex|pi) send_text_submit "/quit" ;;
    grok)
      fm_backend_send_key "$BACKEND" "$TARGET" C-q "$EXPECTED_LABEL"
      sleep 0.2
      fm_backend_send_key "$BACKEND" "$TARGET" C-q "$EXPECTED_LABEL"
      ;;
    *) echo "error: no verified exit command for harness '$HARNESS'" >&2; return 1 ;;
  esac
}

write_pi_extension_if_needed
write_continuation_prompt

exit_agent
sleep "${FM_ROTATE_EXIT_SETTLE:-2}"

mkdir -p "$TASK_TMP/gotmp"
fm_backend_send_text_line "$BACKEND" "$TARGET" "cd $(shell_quote "$WT")" "$EXPECTED_LABEL"
sleep 0.2
fm_backend_send_text_line "$BACKEND" "$TARGET" "export GOTMPDIR=$TASK_TMP/gotmp" "$EXPECTED_LABEL"
sleep 0.2

TURNEND="$STATE/$ID.turn-ended"
LAUNCH=$(launch_template)
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

{
  echo "rotation_handoff=$HANDOFF_ABS"
  echo "rotation_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >> "$META"

echo "rotated $ID on $BACKEND target $TARGET using handoff $HANDOFF_REL"
