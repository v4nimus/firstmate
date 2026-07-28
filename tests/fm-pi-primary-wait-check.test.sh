#!/usr/bin/env bash
# Behavior tests for the Pi-primary long-wait PreToolUse guard.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pi-primary-wait-check.sh"
POLICY="$ROOT/bin/fm-pi-primary-wait-command-policy.mjs"
TMP_ROOT=$(fm_test_tmproot fm-pi-primary-wait-check)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

run_check() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --command "$1"
}

expect_allow() {
  local label=$1 command=$2 out rc
  out=$(run_check "$command" 2>&1)
  rc=$?
  expect_code 0 "$rc" "$label"
  [ -z "$out" ] || fail "$label should be silent on allow: $out"
  pass "$label"
}

expect_deny() {
  local label=$1 command=$2 out rc
  out=$(run_check "$command" 2>&1)
  rc=$?
  expect_code 2 "$rc" "$label"
  assert_contains "$out" "[pi-primary-long-wait]" "$label did not carry the stable reason"
  pass "$label"
}

test_inert_without_live_work() {
  expect_allow "no recorded work leaves long sleeps untouched" "sleep 180"
}

test_static_wait_matrix() {
  touch "$STATE/research.meta"
  expect_allow "short UI-settle sleep remains available" "sleep 2; echo ready"
  expect_allow "quoted sleep text is data, not execution" "printf '%s\n' 'sleep 180'"
  expect_allow "heredoc sleep text is data, not execution" $'cat <<\'EOF\'\nsleep 180\nEOF'
  # shellcheck disable=SC2016
  expect_allow "dynamic sleep duration is not guessed" 'sleep "$delay"'
  expect_deny "one-minute foreground sleep is blocked" "sleep 60"
  expect_deny "multi-operand sleep totals are enforced" "sleep 5 10"
  expect_deny "minute suffix is converted before enforcement" "sleep 2m"
  expect_deny "long sleep in a command list is blocked" "sleep 120; echo poll"
  # shellcheck disable=SC2016
  expect_deny "long sleep in a command substitution is blocked" 'echo "$(sleep 60)"'
  expect_deny "long sleep in a literal shell payload is blocked" "bash -lc 'sleep 180'"
}

test_configurable_threshold() {
  local out rc
  out=$(FM_PI_PRIMARY_MAX_SLEEP_SECS=121 run_check "sleep 120" 2>&1)
  rc=$?
  expect_code 0 "$rc" "configured threshold should allow a smaller static sleep"
  [ -z "$out" ] || fail "configured-threshold allow should be silent: $out"
  pass "maximum static sleep threshold is configurable"
}

test_direct_policy_contract() {
  local out
  out=$(node "$POLICY" --max-seconds 15 --command "sleep 120")
  [ "$out" = $'deny\tpi-primary-long-wait\t120' ] \
    || fail "direct policy deny contract changed: $out"
  out=$(node "$POLICY" --max-seconds 15 --command "printf '%s\n' 'sleep 120'")
  [ "$out" = allow ] || fail "direct policy misclassified quoted data: $out"
  pass "wait command policy has a stable direct contract"
}

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$CHECK" "$0" >/dev/null 2>&1 \
    || fail "Pi-primary wait guard and tests are not shellcheck-clean"
  pass "Pi-primary wait guard and tests are shellcheck-clean"
}

test_inert_without_live_work
test_static_wait_matrix
test_configurable_threshold
test_direct_policy_contract
test_shellcheck_clean

echo "# all fm-pi-primary-wait-check tests passed"
