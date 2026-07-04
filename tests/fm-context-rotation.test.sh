#!/usr/bin/env bash
# Context telemetry, soft rotation wake classification, and rotate command tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-context-lib.sh
. "$ROOT/bin/fm-context-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
ROTATE="$ROOT/bin/fm-rotate.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-rotation)
fm_git_identity fmtest fmtest@example.invalid

reap_pid() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

seen_sig() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

watch_case_bg() {  # <state> <fakebin> <out> <capture-file> [extra env...]
  local state=$1 fakebin=$2 out=$3 capture=$4
  shift 4
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" &
}

make_rotate_fakebin() {
  local dir=$1 fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
CAPTURE="${FM_FAKE_TMUX_CAPTURE:?}"
SENT="${FM_FAKE_TMUX_SENT:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;;
        *pane_current_path*) printf '%s\n' "${FM_FAKE_TMUX_PATH:-}"; exit 0 ;;
        *pane_current_command*)
          cmdfile="${FM_FAKE_TMUX_COMMAND_FILE:-$SENT.command}"
          if [ -f "$cmdfile" ]; then
            cat "$cmdfile"
          else
            printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-claude}"
          fi
          exit 0 ;;
      esac
    done
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    S=""; E=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) S="${2:-}"; shift 2; continue ;;
        -E) E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    if [ -n "$S" ] && [ "$S" = "$E" ]; then
      case "$S" in
        ''|*[!0-9]*) cat "$CAPTURE" 2>/dev/null ;;
        *) awk -v n="$S" 'NR == n + 1 { print; found=1 } END { if (!found) print "" }' "$CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    shift
    lit=0
    text=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter)
          printf '[ENTER]\n' >> "$SENT"
          pending_file="${FM_FAKE_TMUX_PENDING_FILE:-$SENT.pending}"
          cmdfile="${FM_FAKE_TMUX_COMMAND_FILE:-$SENT.command}"
          pending=""; exit_cmd=0
          [ -f "$pending_file" ] && pending=$(cat "$pending_file")
          case "$pending" in
            /exit|/quit) printf 'bash\n' > "$cmdfile"; exit_cmd=1 ;;
            *"claude --dangerously-skip-permissions"*) printf 'claude\n' > "$cmdfile" ;;
            *" codex "*|codex\ *) printf 'codex\n' > "$cmdfile" ;;
            *" opencode "*|opencode\ *) printf 'opencode\n' > "$cmdfile" ;;
            *" pi "*|pi\ *) printf 'pi\n' > "$cmdfile" ;;
            *" grok "*|grok\ *) printf 'grok\n' > "$cmdfile" ;;
          esac
          if [ "$exit_cmd" = 1 ] && [ "${FM_FAKE_TMUX_EXIT_SHELL_PROMPT:-0}" = 1 ]; then
            printf 'Mac:%s wes$ \n' "${FM_FAKE_TMUX_PATH:-wt}" > "$CAPTURE"
          elif [ "${FM_FAKE_TMUX_KEEP_PENDING:-0}" != 1 ]; then
            printf '│ > │\n' > "$CAPTURE"
          fi
          ;;
        C-q|C-c|C-u|Escape)
          printf '[%s]\n' "$1" >> "$SENT"
          ;;
        *)
          if [ "$lit" = 1 ]; then
            text=$1
            printf '%s\n' "$text" >> "$SENT"
            printf '│ > %s │\n' "$text" > "$CAPTURE"
            printf '%s' "$text" > "${FM_FAKE_TMUX_PENDING_FILE:-$SENT.pending}"
          else
            printf '%s\n' "$1" >> "$SENT"
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: fake · idle\n'
SH
  chmod +x "$fakebin/tmux" "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin"
}

make_git_worktree() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm initial
  git -C "$dir" checkout -q -b fm/task
}

test_claude_context_parser_fixture() {
  local out
  out=$(printf 'noise\nFable 5 │ fusor ████████░░ 89%%\n' | fm_context_parse_claude_fullness)
  [ "$out" = 89 ] || fail "Claude fixture footer parsed as '$out', expected 89"
  out=$(printf 'coverage 89%%\n' | fm_context_parse_claude_fullness)
  [ -z "$out" ] || fail "ordinary percentage text should not parse as Claude context"
  out=$(printf 'Downloading model ██████████ 100%%\n' | fm_context_parse_claude_fullness)
  [ -z "$out" ] || fail "non-statusline progress bars should not parse as Claude context"
  out=$(printf 'Codex footer 31%% context left\n' | fm_context_parse_fullness_for_harness codex || true)
  [ -z "$out" ] || fail "Codex context format should stay unsupported until verified"
  pass "context parser reads the verified Claude footer fixture and ignores unverified Codex text"
}

test_current_claude_busy_spinner_fixture() {
  local out
  out=$(printf '%s\n' \
    'Tip: press # to remember' \
    '✢ Pondering… (7s · thinking with xhigh effort)' \
    '                                                              ◉ xhigh · /effort' \
    '────────────────────────────────────────────────────────────────────────────────' \
    '❯ ' \
    '────────────────────────────────────────────────────────────────────────────────' \
    '  Fable 5 │ firstmate' \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents' \
    | bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_capture_has_busy_signature' _ "$ROOT"; printf '%s' "$?")
  [ "$out" = 0 ] || fail "current Claude spinner fixture was not detected as busy"
  out=$(printf '%s\n' '✢ Transfiguring… (15s · ↓ 148 tokens)' \
    | bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_capture_has_busy_signature' _ "$ROOT"; printf '%s' "$?")
  [ "$out" = 0 ] || fail "current Claude token spinner fixture was not detected as busy"
  pass "busy predicate detects current Claude Code spinner rows outside the footer tail"
}

test_crew_state_includes_context_when_available() {
  local dir state fakebin wt out
  dir="$TMP_ROOT/crew-state-context"; state="$dir/state"; fakebin="$dir/fakebin"; wt="$dir/wt"
  mkdir -p "$state" "$fakebin"
  make_git_worktree "$wt"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane) printf 'ready\nFable 5 │ fusor ████████░░ 89%%\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "kind=ship" "harness=claude"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$CREW_STATE" task)
  assert_contains "$out" "context: 89%" "crew-state did not append context telemetry"
  pass "fm-crew-state appends context telemetry when a verified Claude footer is visible"
}

test_crew_state_detects_current_claude_busy_spinner() {
  local dir state fakebin wt out capture
  dir="$TMP_ROOT/crew-state-claude-busy"; state="$dir/state"; fakebin="$dir/fakebin"; wt="$dir/wt"; capture="$dir/pane.txt"
  mkdir -p "$state" "$fakebin"
  make_git_worktree "$wt"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  printf '%s\n' \
    'Tip: press # to remember' \
    '✢ Pondering… (7s · thinking with xhigh effort)' \
    '                                                              ◉ xhigh · /effort' \
    '────────────────────────────────────────────────────────────────────────────────' \
    '❯ ' \
    '────────────────────────────────────────────────────────────────────────────────' \
    '  Fable 5 │ firstmate' \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents' > "$capture"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "kind=ship" "harness=claude"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_CAPTURE="$capture" "$CREW_STATE" task)
  assert_contains "$out" "state: working" "crew-state did not report current Claude spinner as working"
  assert_contains "$out" "source: pane" "crew-state did not attribute current Claude spinner to pane busy state"
  pass "fm-crew-state detects the current Claude Code spinner as a busy pane"
}

test_watcher_rotation_due_on_turn_boundary() {
  local dir state fakebin out drain_out capture pid
  dir=$(make_case rotation-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
  printf 'idle\nFable 5 │ fusor ████████░░ 89%%\n' > "$capture"
  fm_write_meta "$state/task.meta" "window=test:fm-task" "kind=ship" "harness=claude"
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_case_bg "$state" "$fakebin" "$out" "$capture"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a high-context turn boundary"
  grep -Fx "rotation-due: task 89%" "$out" >/dev/null || fail "watcher did not print rotation-due reason: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after rotation-due failed"
  grep "$(printf '\trotation-due\t')" "$drain_out" | grep -F "rotation-due: task 89%" >/dev/null || fail "rotation-due wake was not queued"
  pass "watcher surfaces rotation-due at a high-context turn boundary"
}

test_watcher_rotation_never_mid_turn() {
  local dir state fakebin out capture pid
  dir=$(make_case rotation-busy); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf 'working\nFable 5 │ fusor ████████░░ 89%%\n' > "$capture"
  fm_write_meta "$state/task.meta" "window=test:fm-task" "kind=ship" "harness=claude"
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_case_bg "$state" "$fakebin" "$out" "$capture"
  pid=$!
  if ! wait_live "$pid" 30; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while crew was still provably working: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap_pid "$pid"; fail "busy rotation check enqueued a wake"; }
  reap_pid "$pid"
  pass "watcher does not fire rotation-due while the crew is mid-turn"
}

test_watcher_rotation_suppresses_same_signature() {
  local dir state fakebin out capture sig pid
  dir=$(make_case rotation-suppress); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf 'idle\nFable 5 │ fusor ████████░░ 89%%\n' > "$capture"
  fm_write_meta "$state/task.meta" "window=test:fm-task" "kind=ship" "harness=claude"
  : > "$state/task.turn-ended"
  sig=$(seen_sig "$state/task.turn-ended")
  printf 'pct=89 sig=signal:%s' "$sig" > "$state/.rotation-seen-task"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_case_bg "$state" "$fakebin" "$out" "$capture"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher should still surface the stopped turn as a normal signal"
  grep -Fx "rotation-due: task 89%" "$out" >/dev/null && fail "rotation-due repeated for the same signal signature"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "suppressed rotation should fall through to normal signal handling"
  pass "rotation-due suppresses repeats until the turn-boundary signature changes"
}

test_watcher_skips_rotation_due_for_unsupported_backend() {
  local dir state fakebin out capture pid
  dir=$(make_case rotation-unsupported-backend); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf 'idle\nFable 5 │ fusor ████████░░ 89%%\n' > "$capture"
  fm_write_meta "$state/task.meta" "window=test:fm-task" "backend=zellij" "kind=ship" "harness=claude"
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_case_bg "$state" "$fakebin" "$out" "$capture"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher should surface unsupported-backend turn-ended as a normal signal"
  grep -Fx "rotation-due: task 89%" "$out" >/dev/null && fail "unsupported backend emitted a doomed rotation-due wake"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "unsupported backend turn-ended did not fall through to signal handling"
  pass "watcher does not emit rotation-due for backends fm-rotate cannot relaunch"
}

test_watcher_terminal_signal_wins_over_rotation() {
  local dir state fakebin out drain_out capture pid
  dir=$(make_case rotation-terminal-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
  printf 'idle\nFable 5 │ fusor ████████░░ 89%%\n' > "$capture"
  fm_write_meta "$state/task.meta" "window=test:fm-task" "kind=ship" "harness=claude"
  : > "$state/task.turn-ended"
  printf 'done: ready for review\n' > "$state/task.status"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_case_bg "$state" "$fakebin" "$out" "$capture"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for terminal signal"
  grep -F "signal: " "$out" >/dev/null || fail "watcher did not surface signal first: $(cat "$out")"
  grep -Fx "rotation-due: task 89%" "$out" >/dev/null && fail "terminal signal should not be preempted by rotation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after terminal signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "signal:" >/dev/null || fail "terminal signal wake was not queued"
  grep "$(printf '\trotation-due\t')" "$drain_out" >/dev/null && fail "rotation wake should not be queued ahead of terminal signal"
  pass "watcher surfaces terminal signal before any rotation"
}

test_watcher_terminal_stale_wins_over_rotation() {
  local dir state fakebin out drain_out capture pid
  dir=$(make_case rotation-terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"; capture="$dir/pane.txt"
  printf 'idle\nFable 5 │ fusor ████████░░ 89%%\n' > "$capture"
  fm_write_meta "$state/task.meta" "window=test:fm-task" "kind=ship" "harness=claude"
  printf 'done: ready for review\n' > "$state/task.status"
  seen_sig "$state/task.status" > "$state/.seen-task_status"
  key=$(printf '%s' "test:fm-task" | tr ':/.' '___')
  if command -v md5 >/dev/null 2>&1; then
    hash=$(md5 -q "$capture")
  else
    hash=$(md5sum "$capture" | awk '{print $1}')
  fi
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle'
  watch_case_bg "$state" "$fakebin" "$out" "$capture"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for terminal stale"
  grep -Fx "stale: test:fm-task" "$out" >/dev/null || fail "watcher did not surface terminal stale first: $(cat "$out")"
  grep -Fx "rotation-due: task 89%" "$out" >/dev/null && fail "terminal stale should not be preempted by rotation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: test:fm-task" >/dev/null || fail "terminal stale wake was not queued"
  grep "$(printf '\trotation-due\t')" "$drain_out" >/dev/null && fail "rotation wake should not be queued ahead of terminal stale"
  pass "watcher surfaces terminal stale before any rotation"
}

test_rotate_requests_missing_handoff() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-missing"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'ordinary rotation documentation, not a task handoff\n' > "$wt/docs/context-rotation.md"
  printf 'old generic handoff, not for this task\n' > "$wt/docs/handoff.md"
  git -C "$wt" add docs/context-rotation.md
  git -C "$wt" add docs/handoff.md
  git -C "$wt" commit -qm docs
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_WAIT_SECS=0 FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "rotate without handoff should exit 3, got $status: $out"
  assert_contains "$(cat "$sent")" "Context rotation is due" "rotate did not request a handoff"
  pass "fm-rotate can request a committed handoff and return without waiting"
}

test_rotate_requests_handoff_before_dirty_refusal() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-dirty-missing"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  printf 'uncommitted task work\n' >> "$wt/README.md"
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_WAIT_SECS=0 FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "dirty rotate without handoff should request and exit 3, got $status: $out"
  assert_contains "$(cat "$sent")" "Context rotation is due" "dirty rotate without handoff did not request a handoff"
  assert_not_contains "$out" "REFUSED: worktree" "dirty rotate without handoff refused before requesting handoff"
  pass "fm-rotate requests a handoff before dirty refusal"
}

test_rotate_refuses_dirty_after_committed_handoff() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-dirty-ready"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  printf 'uncommitted task work\n' >> "$wt/README.md"
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "dirty rotate with handoff should refuse before relaunch, got $status: $out"
  assert_contains "$out" "uncommitted changes after handoff wait" "dirty rotate with handoff did not explain refusal"
  grep -F "/exit" "$sent" >/dev/null && fail "dirty rotate with handoff exited before refusing dirty worktree"
  pass "fm-rotate refuses dirty work before relaunch"
}

test_rotate_refuses_current_claude_busy_spinner_before_exit() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-claude-busy"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '%s\n' \
    'Tip: press # to remember' \
    '✢ Pondering… (7s · thinking with xhigh effort)' \
    '                                                              ◉ xhigh · /effort' \
    '────────────────────────────────────────────────────────────────────────────────' \
    '❯ ' \
    '────────────────────────────────────────────────────────────────────────────────' \
    '  Fable 5 │ firstmate' \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents' > "$cap"
  : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_CURSOR_Y=4 FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "rotate should refuse visible Claude busy spinner, got $status: $out"
  assert_contains "$out" "busy signature" "rotate did not explain the busy-spinner refusal"
  assert_not_contains "$(cat "$sent")" "/exit" "rotate sent /exit while the current Claude spinner was visible"
  pass "fm-rotate refuses to exit a pane showing the current Claude busy spinner"
}

test_rotate_accepts_explicit_generic_handoff() {
  local dir state data wt fakebin sent cap out
  dir="$TMP_ROOT/rotate-explicit"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'explicitly selected handoff\n' > "$wt/docs/handoff.md"
  git -C "$wt" add docs/handoff.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task --handoff docs/handoff.md)
  assert_contains "$out" "rotated task" "rotate did not accept explicit committed handoff"
  assert_grep "rotation_handoff=$wt/docs/handoff.md" "$state/task.meta" "rotate did not record explicit handoff"
  pass "fm-rotate accepts explicit committed generic handoff"
}

test_rotate_refuses_explicit_stale_handoff() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-explicit-stale"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'old selected handoff\n' > "$wt/docs/handoff.md"
  git -C "$wt" add docs/handoff.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp" "rotation_handoff=$wt/docs/handoff.md" "rotation_at=2099-01-01T00:00:00Z"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task --handoff docs/handoff.md 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "explicit stale handoff should fail, got $status: $out"
  assert_contains "$out" "not newer than the previous rotation" "stale explicit handoff refusal was not clear"
  assert_not_contains "$(cat "$sent")" "/exit" "stale explicit handoff exited before refusing"
  pass "fm-rotate refuses an explicit stale handoff"
}

test_rotate_autodetects_marked_handoff() {
  local dir state data wt fakebin sent cap out
  dir="$TMP_ROOT/rotate-marker"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'Task ID: task\nmarked handoff\n' > "$wt/docs/handoff.md"
  git -C "$wt" add docs/handoff.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task)
  assert_contains "$out" "rotated task" "rotate did not autodetect marked handoff"
  assert_grep "rotation_handoff=$wt/docs/handoff.md" "$state/task.meta" "rotate did not record marked handoff"
  pass "fm-rotate autodetects a committed handoff with an explicit task marker"
}

test_rotate_ignores_autodetected_stale_handoff() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-marker-stale"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'Task ID: task\nold marked handoff\n' > "$wt/docs/handoff.md"
  git -C "$wt" add docs/handoff.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp" "rotation_handoff=$wt/docs/handoff.md" "rotation_at=2099-01-01T00:00:00Z"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_WAIT_SECS=0 FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "autodetected stale handoff should request a fresh handoff, got $status: $out"
  assert_contains "$out" "rotation pending handoff" "stale autodetected handoff did not request a fresh handoff"
  assert_contains "$(cat "$sent")" "Context rotation is due" "stale autodetected handoff did not send the handoff request"
  assert_not_contains "$(cat "$sent")" "/exit" "stale autodetected handoff exited before a fresh handoff"
  pass "fm-rotate ignores autodetected stale handoffs"
}

test_rotate_refuses_grok_orca_before_exit() {
  local dir state data wt status out
  dir="$TMP_ROOT/rotate-grok-orca"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fm_write_meta "$state/task.meta" "window=fm-task" "terminal=term-task" "backend=orca" "worktree=$wt" "project=$wt" "harness=grok" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "grok/orca rotate should fail before exit, got $status: $out"
  assert_contains "$out" "harness=grok on backend=orca is unsupported" "grok/orca refusal was not clear"
  [ ! -e "$data/task/rotation-prompt.md" ] || fail "grok/orca refusal should not write a continuation prompt"
  pass "fm-rotate fails closed for Grok on Orca before exit or relaunch"
}

test_rotate_refuses_unsupported_shell_ready_before_exit() {
  local dir state data wt status out sent
  dir="$TMP_ROOT/rotate-zellij-unsupported"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fm_write_meta "$state/task.meta" "window=zellij-session:pane-task" "backend=zellij" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  : > "$sent"
  set +e
  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_FAKE_ZELLIJ_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "zellij rotate should fail before exit, got $status: $out"
  assert_contains "$out" "shell readiness cannot be verified" "unsupported backend refusal was not clear"
  assert_not_contains "$(cat "$sent")" "/exit" "unsupported backend rotate exited before refusing"
  pass "fm-rotate refuses unsupported shell-readiness backends before exit"
}

test_rotate_refuses_unsupported_backend_before_handoff_request() {
  local dir state data wt status out sent
  dir="$TMP_ROOT/rotate-zellij-unsupported-no-handoff"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  fm_write_meta "$state/task.meta" "window=zellij-session:pane-task" "backend=zellij" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  : > "$sent"
  set +e
  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_FAKE_ZELLIJ_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "unsupported backend without handoff should fail before request, got $status: $out"
  assert_contains "$out" "shell readiness cannot be verified" "unsupported backend refusal was not clear"
  [ ! -s "$sent" ] || fail "unsupported backend received a handoff or exit send before refusal: $(cat "$sent")"
  [ ! -e "$data/task/rotation-prompt.md" ] || fail "unsupported backend wrote a continuation prompt before refusal"
  pass "fm-rotate refuses unsupported backends before requesting a handoff"
}

test_rotate_refuses_unconfirmed_exit_submit() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-unconfirmed-exit"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_EXIT_ACK_TIMEOUT=0 FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_TMUX_KEEP_PENDING=1 "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "rotate should refuse unconfirmed exit submit, got $status: $out"
  assert_contains "$out" "not acknowledged by an empty composer or verified shell" "rotate did not explain unconfirmed exit submit"
  grep -F "export GOTMPDIR" "$sent" >/dev/null && fail "rotate continued with shell commands after unconfirmed exit"
  assert_contains "$(cat "$sent")" "[C-u]" "rotate did not try to clear the unsubmitted exit text after a failed submit"
  pass "fm-rotate refuses to relaunch after an unconfirmed exit submit"
}

test_rotate_accepts_shell_prompt_as_exit_ack() {
  local dir state data wt fakebin sent cap out cmdfile
  dir="$TMP_ROOT/rotate-shell-prompt-ack"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"; cmdfile="$dir/current-command"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"; printf 'claude\n' > "$cmdfile"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_COMMAND_FILE="$cmdfile" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_TMUX_EXIT_SHELL_PROMPT=1 "$ROTATE" task)
  assert_contains "$out" "rotated task" "rotate did not report success when /exit exposed a shell prompt"
  assert_contains "$(cat "$sent")" "/exit" "rotate did not send the exit command"
  assert_contains "$(cat "$sent")" "export GOTMPDIR" "rotate did not continue after verified shell-ready exit acknowledgement"
  assert_contains "$(cat "$sent")" "claude --dangerously-skip-permissions" "rotate did not relaunch Claude after shell-ready exit acknowledgement"
  pass "fm-rotate accepts verified shell readiness as the /exit acknowledgement"
}

test_rotate_relaunches_from_already_exited_shell() {
  local dir state data wt fakebin sent cap out cmdfile
  dir="$TMP_ROOT/rotate-already-shell"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"; cmdfile="$dir/current-command"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf 'Mac:%s wes$ \n' "$wt" > "$cap"; : > "$sent"; printf 'bash\n' > "$cmdfile"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_COMMAND_FILE="$cmdfile" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task)
  assert_contains "$out" "rotated task" "rotate did not recover a pane that was already at a verified shell"
  assert_not_contains "$(cat "$sent")" "/exit" "already-exited recovery should not send another exit command"
  assert_contains "$(cat "$sent")" "claude --dangerously-skip-permissions" "already-exited recovery did not relaunch Claude"
  pass "fm-rotate relaunches when a previous attempt already left the pane at a shell"
}

test_rotate_waits_for_verified_shell_before_relaunch() {
  local dir state data wt fakebin sent cap out cmdfile pid i
  dir="$TMP_ROOT/rotate-shell-ready"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"; out="$dir/out"; cmdfile="$dir/current-command"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  printf 'claude\n' > "$cmdfile"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_EXIT_TIMEOUT=5 FM_ROTATE_EXIT_POLL_SECS=1 FM_FAKE_TMUX_COMMAND_FILE="$cmdfile" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task > "$out" 2>&1 &
  pid=$!
  for i in $(seq 1 20); do
    grep -F "/exit" "$sent" >/dev/null 2>&1 && break
    sleep 0.1
  done
  sleep 1
  grep -F "export GOTMPDIR" "$sent" >/dev/null && { reap_pid "$pid"; fail "rotate sent relaunch commands before shell readiness was verified"; }
  printf 'bash\n' > "$cmdfile"
  wait_for_exit "$pid" 80 || { reap_pid "$pid"; fail "rotate did not finish after shell became ready: $(cat "$out")"; }
  assert_contains "$(cat "$out")" "rotated task" "rotate did not report success after shell readiness"
  assert_contains "$(cat "$sent")" "export GOTMPDIR" "rotate did not send relaunch commands after shell readiness"
  pass "fm-rotate waits for a verified shell before relaunch commands"
}

test_rotate_waits_for_handoff_then_relaunches() {
  local dir state data wt fakebin sent cap out pid i
  dir="$TMP_ROOT/rotate-wait"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"; out="$dir/out"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_WAIT_SECS=5 FM_ROTATE_WAIT_POLL_SECS=1 FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task > "$out" 2>&1 &
  pid=$!
  for i in $(seq 1 40); do
    grep -F "Context rotation is due" "$sent" >/dev/null 2>&1 && break
    sleep 0.1
  done
  grep -F "Context rotation is due" "$sent" >/dev/null 2>&1 || { reap_pid "$pid"; fail "rotate did not request handoff before waiting"; }
  mkdir -p "$wt/docs"
  printf 'handoff after request\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  wait_for_exit "$pid" 80 || { reap_pid "$pid"; fail "rotate did not finish after handoff appeared: $(cat "$out")"; }
  assert_contains "$(cat "$out")" "rotated task" "rotate did not report success after waiting"
  assert_contains "$(cat "$sent")" "/exit" "rotate did not exit after waited handoff"
  assert_contains "$(cat "$sent")" "claude --dangerously-skip-permissions" "rotate did not relaunch after waited handoff"
  pass "fm-rotate waits for a committed handoff then relaunches"
}

test_rotate_relaunches_same_worktree_with_committed_handoff() {
  local dir state data wt fakebin sent cap out brief_dir
  dir="$TMP_ROOT/rotate-ready"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task)
  assert_contains "$out" "rotated task" "rotate did not report success"
  assert_contains "$(cat "$sent")" "/exit" "rotate did not exit the old harness"
  assert_contains "$(cat "$sent")" "cd '$wt'" "rotate did not return to the same worktree"
  assert_contains "$(cat "$sent")" "claude --dangerously-skip-permissions" "rotate did not relaunch Claude"
  assert_grep "rotation_handoff=$wt/docs/firstmate-handoff-task.md" "$state/task.meta" "rotate did not record the handoff"
  brief_dir=$(cd "$data/task" && pwd -P)
  assert_contains "$(cat "$data/task/rotation-prompt.md")" "original task brief before making changes: $brief_dir/brief.md" "rotate continuation prompt did not include the original brief path"
  pass "fm-rotate exits and relaunches in the same worktree after a committed handoff"
}

test_rotate_refuses_secondmate_parent_side() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-secondmate-refuse"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'handoff\n' > "$wt/docs/firstmate-handoff-task.md"
  git -C "$wt" add docs/firstmate-handoff-task.md
  git -C "$wt" commit -qm handoff
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=codex" "kind=secondmate" "mode=secondmate" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_PATH="$wt" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "secondmate parent-side rotate should refuse, got $status: $out"
  assert_contains "$out" "kind=secondmate" "secondmate refusal did not explain the unsupported contract"
  assert_not_contains "$(cat "$sent")" "/quit" "secondmate refusal should happen before exit"
  [ ! -e "$data/task/rotation-prompt.md" ] || fail "secondmate refusal should not write a continuation prompt"
  pass "fm-rotate refuses parent-side secondmate rotation until a real secondmate stow contract exists"
}

test_claude_context_parser_fixture
test_current_claude_busy_spinner_fixture
test_crew_state_includes_context_when_available
test_crew_state_detects_current_claude_busy_spinner
test_watcher_rotation_due_on_turn_boundary
test_watcher_rotation_never_mid_turn
test_watcher_rotation_suppresses_same_signature
test_watcher_skips_rotation_due_for_unsupported_backend
test_watcher_terminal_signal_wins_over_rotation
test_watcher_terminal_stale_wins_over_rotation
test_rotate_requests_missing_handoff
test_rotate_requests_handoff_before_dirty_refusal
test_rotate_refuses_dirty_after_committed_handoff
test_rotate_refuses_current_claude_busy_spinner_before_exit
test_rotate_accepts_explicit_generic_handoff
test_rotate_refuses_explicit_stale_handoff
test_rotate_autodetects_marked_handoff
test_rotate_ignores_autodetected_stale_handoff
test_rotate_refuses_grok_orca_before_exit
test_rotate_refuses_unsupported_shell_ready_before_exit
test_rotate_refuses_unsupported_backend_before_handoff_request
test_rotate_refuses_unconfirmed_exit_submit
test_rotate_accepts_shell_prompt_as_exit_ack
test_rotate_relaunches_from_already_exited_shell
test_rotate_waits_for_verified_shell_before_relaunch
test_rotate_waits_for_handoff_then_relaunches
test_rotate_relaunches_same_worktree_with_committed_handoff
test_rotate_refuses_secondmate_parent_side
