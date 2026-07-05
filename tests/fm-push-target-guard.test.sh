#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh's GitHub push-target ownership diagnostic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-push-target-tests)

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then
  [ "${FM_FAKE_GH_USER_FAIL:-0}" = 1 ] && exit 1
  printf '%s\n' captain
  exit 0
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    repos/captain/*) printf 'User\ttrue\n' ;;
    repos/org-admin/*) printf 'Organization\ttrue\n' ;;
    repos/org-viewer/*) printf 'Organization\tfalse\n' ;;
    repos/*) printf 'User\tfalse\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/config" "$home/projects"
  printf '%s\n' manual > "$home/config/backlog-backend"
}

make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
  git -C "$dir" branch -M main
}

bootstrap_out() {
  local root=$1 home=$2 fakebin=$3
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh"
}

test_owned_push_url_passes() {
  local case_dir root home fakebin out
  case_dir="$TMP_ROOT/owned"
  root="$case_dir/root"
  home="$case_dir/home"
  make_repo "$root"
  make_home "$home"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$root" remote set-url --push origin git@github.com:captain/firstmate.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin")

  assert_not_contains "$out" "PUSH_TARGET:" "owned GitHub push URLs must pass silently"
  pass "push-target guard accepts captain-owned GitHub push URLs"
}

test_owned_push_url_case_insensitive_passes() {
  local case_dir root home fakebin out
  case_dir="$TMP_ROOT/owned-case"
  root="$case_dir/root"
  home="$case_dir/home"
  make_repo "$root"
  make_home "$home"
  git -C "$root" remote add origin https://github.com/Captain/firstmate.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin")

  assert_not_contains "$out" "PUSH_TARGET:" "GitHub owner/login matching must be case-insensitive"
  pass "push-target guard accepts captain-owned GitHub push URLs regardless of case"
}

test_non_owned_explicit_push_url_flags() {
  local case_dir root home project fakebin out expect
  case_dir="$TMP_ROOT/non-owned"
  root="$case_dir/root"
  home="$case_dir/home"
  project="$home/projects/alpha"
  make_repo "$root"
  make_home "$home"
  make_repo "$project"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$project" remote add upstream https://github.com/captain/alpha.git
  git -C "$project" remote set-url --push upstream https://github.com/other/alpha.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin" | grep '^PUSH_TARGET:' || true)
  expect="PUSH_TARGET: alpha: upstream pushes to non-owned https://github.com/other/alpha.git - disable with: git -C '$project' config --replace-all 'remote.upstream.pushurl' no_push://disabled-not-our-repo"

  [ "$out" = "$expect" ] || fail "non-owned push URL diagnostic mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "push-target guard flags explicit non-owned GitHub push URLs with remediation"
}

test_multiple_push_urls_remediation_replaces_full_set() {
  local case_dir root home project fakebin out expect cmd urls
  case_dir="$TMP_ROOT/multiple-pushurls"
  root="$case_dir/root"
  home="$case_dir/home"
  project="$home/projects/theta"
  make_repo "$root"
  make_home "$home"
  make_repo "$project"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$project" remote add upstream https://github.com/captain/theta.git
  git -C "$project" remote set-url --push --add upstream https://github.com/other/theta.git
  git -C "$project" remote set-url --push --add upstream https://github.com/captain/theta.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin" | grep '^PUSH_TARGET:' || true)
  expect="PUSH_TARGET: theta: upstream pushes to non-owned https://github.com/other/theta.git - disable with: git -C '$project' config --replace-all 'remote.upstream.pushurl' no_push://disabled-not-our-repo"
  [ "$out" = "$expect" ] || fail "multiple push URL diagnostic mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"

  cmd=${out#* - disable with: }
  eval "$cmd"
  urls=$(git -C "$project" remote get-url --push --all upstream)
  [ "$urls" = "no_push://disabled-not-our-repo" ] \
    || fail "safe-disable remediation should replace the full push-url set, got: $urls"
  pass "push-target remediation replaces the full push-url set"
}

test_no_push_url_passes() {
  local case_dir root home project fakebin out
  case_dir="$TMP_ROOT/no-push"
  root="$case_dir/root"
  home="$case_dir/home"
  project="$home/projects/beta"
  make_repo "$root"
  make_home "$home"
  make_repo "$project"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$project" remote add upstream https://github.com/other/beta.git
  git -C "$project" remote set-url --push upstream no_push://disabled-not-our-repo
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin")

  assert_not_contains "$out" "PUSH_TARGET:" "no_push:// push URLs must pass silently"
  pass "push-target guard accepts the disabled no_push:// push-url pattern"
}

test_fetch_url_fallback_is_scanned() {
  local case_dir root home project fakebin out
  case_dir="$TMP_ROOT/fetch-fallback"
  root="$case_dir/root"
  home="$case_dir/home"
  project="$home/projects/gamma"
  make_repo "$root"
  make_home "$home"
  make_repo "$project"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$project" remote add upstream https://github.com/other/gamma.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin" | grep '^PUSH_TARGET:' || true)

  assert_contains "$out" "PUSH_TARGET: gamma: upstream pushes to non-owned https://github.com/other/gamma.git" \
    "remotes with no explicit pushurl still default-push to their fetch URL and must be scanned"
  pass "push-target guard scans Git's fetch-URL push fallback"
}

test_org_without_verified_admin_flags_distinctly() {
  local case_dir root home project fakebin out
  case_dir="$TMP_ROOT/org-unverified"
  root="$case_dir/root"
  home="$case_dir/home"
  project="$home/projects/delta"
  make_repo "$root"
  make_home "$home"
  make_repo "$project"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$project" remote add upstream https://github.com/org-viewer/delta.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(bootstrap_out "$root" "$home" "$fakebin" | grep '^PUSH_TARGET:' || true)

  assert_contains "$out" "pushes to org GitHub repo not verified as captain-admin https://github.com/org-viewer/delta.git" \
    "org repos without verified admin permission need distinct wording"
  pass "push-target guard distinguishes org repos without verified captain admin"
}

test_gh_unavailable_skips_without_false_alarm() {
  local case_dir root home project fakebin out
  case_dir="$TMP_ROOT/gh-skip"
  root="$case_dir/root"
  home="$case_dir/home"
  project="$home/projects/epsilon"
  make_repo "$root"
  make_home "$home"
  make_repo "$project"
  git -C "$root" remote add origin https://github.com/captain/firstmate.git
  git -C "$project" remote add upstream https://github.com/other/epsilon.git
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_GH_USER_FAIL=1 bootstrap_out "$root" "$home" "$fakebin" | grep '^PUSH_TARGET:' || true)

  [ "$out" = "PUSH_TARGET: skipped: GitHub ownership unavailable (gh api user failed)" ] \
    || fail "gh-unavailable path should skip exactly once, got: $out"
  pass "push-target guard skips when GitHub identity cannot be resolved"
}

test_owned_push_url_passes
test_owned_push_url_case_insensitive_passes
test_non_owned_explicit_push_url_flags
test_multiple_push_urls_remediation_replaces_full_set
test_no_push_url_passes
test_fetch_url_fallback_is_scanned
test_org_without_verified_admin_flags_distinctly
test_gh_unavailable_skips_without_false_alarm
