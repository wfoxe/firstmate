#!/usr/bin/env bash
# fm-run launcher wrapper tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$ROOT/bin/fm-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-run)

test_default_harness_launch_carries_session_start_prompt() {
  local dir fakebin home log out
  dir="$TMP_ROOT/default-prompt"; fakebin="$dir/fakebin"; home="$dir/home"; log="$dir/claude.args"
  mkdir -p "$fakebin" "$home/state"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_FAKE_CLAUDE_ARGS:?}"
exit 0
SH
  chmod +x "$fakebin/claude"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_CLAUDE_ARGS="$log" "$RUN" --harness claude --once 2>&1)
  [ -z "$out" ] || true
  assert_contains "$(cat "$log")" "bin/fm-session-start.sh" "fm-run default Claude launch did not carry the session-start prompt"
  assert_contains "$(cat "$log")" "fm-watch-arm.sh" "fm-run default prompt did not instruct supervision re-arm"
  pass "fm-run default harness launch starts a real firstmate supervision turn"
}

test_stop_file_prevents_launch() {
  local dir fakebin home log out status
  dir="$TMP_ROOT/stop-file"; fakebin="$dir/fakebin"; home="$dir/home"; log="$dir/claude.args"
  mkdir -p "$fakebin" "$home/state"
  : > "$home/state/.fm-run-stop"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "launched" > "${FM_FAKE_CLAUDE_ARGS:?}"
exit 0
SH
  chmod +x "$fakebin/claude"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_CLAUDE_ARGS="$log" "$RUN" --harness claude --once 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "fm-run stop-file path should exit 0, got $status: $out"
  assert_contains "$out" "stop file present" "fm-run did not explain the stop-file refusal"
  [ ! -e "$log" ] || fail "fm-run launched the harness despite the stop file"
  pass "fm-run stop file prevents an automatic relaunch"
}

test_default_harness_launch_carries_session_start_prompt
test_stop_file_prevents_launch
