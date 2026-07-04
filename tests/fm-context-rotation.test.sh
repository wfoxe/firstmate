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
      case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac
    done
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    cat "$CAPTURE" 2>/dev/null
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
          printf '│ > │\n' > "$CAPTURE"
          ;;
        C-q|C-c|Escape)
          printf '[%s]\n' "$1" >> "$SENT"
          ;;
        *)
          if [ "$lit" = 1 ]; then
            text=$1
            printf '%s\n' "$text" >> "$SENT"
            printf '│ > %s │\n' "$text" > "$CAPTURE"
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
  out=$(printf 'Codex footer 31%% context left\n' | fm_context_parse_fullness_for_harness codex || true)
  [ -z "$out" ] || fail "Codex context format should stay unsupported until verified"
  pass "context parser reads the verified Claude footer fixture and ignores unverified Codex text"
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

test_rotate_requests_missing_handoff() {
  local dir state data wt fakebin sent cap status out
  dir="$TMP_ROOT/rotate-missing"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  mkdir -p "$wt/docs"
  printf 'ordinary rotation documentation, not a task handoff\n' > "$wt/docs/context-rotation.md"
  git -C "$wt" add docs/context-rotation.md
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

test_rotate_waits_for_handoff_then_relaunches() {
  local dir state data wt fakebin sent cap out pid i
  dir="$TMP_ROOT/rotate-wait"; state="$dir/state"; data="$dir/data"; wt="$dir/wt"; sent="$dir/sent"; cap="$dir/capture"; out="$dir/out"
  mkdir -p "$state" "$data"
  make_git_worktree "$wt"
  fakebin=$(make_rotate_fakebin "$dir")
  printf '│ > │\n' > "$cap"; : > "$sent"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "tasktmp=$dir/tmp"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_ROTATE_WAIT_SECS=5 FM_ROTATE_WAIT_POLL_SECS=1 FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task > "$out" 2>&1 &
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
  local dir state data wt fakebin sent cap out
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
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_TMUX_CAPTURE="$cap" FM_FAKE_TMUX_SENT="$sent" "$ROTATE" task)
  assert_contains "$out" "rotated task" "rotate did not report success"
  assert_contains "$(cat "$sent")" "/exit" "rotate did not exit the old harness"
  assert_contains "$(cat "$sent")" "cd '$wt'" "rotate did not return to the same worktree"
  assert_contains "$(cat "$sent")" "claude --dangerously-skip-permissions" "rotate did not relaunch Claude"
  assert_grep "rotation_handoff=$wt/docs/firstmate-handoff-task.md" "$state/task.meta" "rotate did not record the handoff"
  pass "fm-rotate exits and relaunches in the same worktree after a committed handoff"
}

test_claude_context_parser_fixture
test_crew_state_includes_context_when_available
test_watcher_rotation_due_on_turn_boundary
test_watcher_rotation_never_mid_turn
test_watcher_rotation_suppresses_same_signature
test_rotate_requests_missing_handoff
test_rotate_waits_for_handoff_then_relaunches
test_rotate_relaunches_same_worktree_with_committed_handoff
