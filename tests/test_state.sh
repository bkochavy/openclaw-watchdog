#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_LIB="$ROOT_DIR/scripts/lib/state.sh"

PASS_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$message (expected='$expected' actual='$actual')"
  fi
}

assert_nonempty() {
  local value="$1" message="$2"
  [ -n "$value" ] || fail "$message"
}

mktemp_dir() {
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-state-test
}

# 1) init creates default state schema
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  sentinel_state_init "$state_file"

  [ -f "$state_file" ] || fail "state file should be created"
  assert_eq "2" "$(jq -r '.version' "$state_file")" "state version should be 2"
  assert_eq "0" "$(jq -r '.health.consecutive_failures' "$state_file")" "failures should default to 0"
)
pass "state init writes default schema"

# 2) read auto-initializes missing state file
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  state_json="$(sentinel_state_read "$state_file")"

  assert_eq "2" "$(jq -r '.version' <<<"$state_json")" "read should initialize missing file"
)
pass "state read auto-initializes file"

# 3) write + get roundtrip
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  custom_json='{"version":2,"updated_at":"2026-01-01T00:00:00Z","health":{"consecutive_failures":7,"last_healthy_at":null,"current_incident_id":null},"incident":{"id":null,"started_at":null,"tier_reached":0,"repairs_attempted":0,"last_repair_at":null,"rescue_announced":false,"pre_repair_backup_sha":null},"backup":{"last_system_backup_at":null,"last_memory_backup_at":null,"last_push_at":null,"last_push_verified":false,"last_manifest_sha":null,"alert_dedup_key":""}}'

  sentinel_state_write "$state_file" "$custom_json"
  assert_eq "7" "$(sentinel_state_get "$state_file" '.health.consecutive_failures' '0')" "get should return stored value"
)
pass "state write/read roundtrip"

# 4) mark_health_failure increments failures
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  sentinel_state_init "$state_file"
  sentinel_state_mark_health_failure "$state_file"
  sentinel_state_mark_health_failure "$state_file"

  assert_eq "2" "$(sentinel_state_get "$state_file" '.health.consecutive_failures' '0')" "health failure should increment counter"
)
pass "health failure increments counter"

# 5) incident lifecycle fields are set and incremented correctly
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  sentinel_state_init "$state_file"
  sentinel_state_ensure_incident "$state_file"

  incident_id="$(sentinel_state_get "$state_file" '.incident.id' '')"
  assert_nonempty "$incident_id" "incident id should be set"
  assert_eq "$incident_id" "$(sentinel_state_get "$state_file" '.health.current_incident_id' '')" "health incident pointer should match incident id"

  sentinel_state_set_tier "$state_file" 3
  sentinel_state_increment_repairs "$state_file"
  sentinel_state_set_rescue_announced "$state_file" true
  sentinel_state_set_pre_repair_backup_sha "$state_file" "sha-123"

  assert_eq "3" "$(sentinel_state_get "$state_file" '.incident.tier_reached' '0')" "tier should be set"
  assert_eq "1" "$(sentinel_state_get "$state_file" '.incident.repairs_attempted' '0')" "repairs should increment"
  assert_eq "true" "$(sentinel_state_get "$state_file" '.incident.rescue_announced' 'false')" "rescue flag should be true"
  assert_eq "sha-123" "$(sentinel_state_get "$state_file" '.incident.pre_repair_backup_sha' '')" "pre-repair sha should be stored"
)
pass "incident lifecycle updates state"

# 6) mark_health_success resets incident and records last healthy timestamp
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  sentinel_state_init "$state_file"
  sentinel_state_mark_health_failure "$state_file"
  sentinel_state_ensure_incident "$state_file"
  sentinel_state_set_tier "$state_file" 4
  sentinel_state_increment_repairs "$state_file"

  sentinel_state_mark_health_success "$state_file"

  assert_eq "0" "$(sentinel_state_get "$state_file" '.health.consecutive_failures' '9')" "health success should reset failures"
  assert_eq "null" "$(jq -r '.incident.id' "$state_file")" "incident id should reset to null"
  assert_eq "0" "$(sentinel_state_get "$state_file" '.incident.tier_reached' '9')" "incident tier should reset"
  assert_nonempty "$(sentinel_state_get "$state_file" '.health.last_healthy_at' '')" "last healthy timestamp should be set"
)
pass "health success closes incident"

# 7) reset_incident leaves backup snapshot intact while clearing incident state
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  sentinel_state_init "$state_file"
  sentinel_state_set_backup_snapshot "$state_file" "2026-03-02T04:00:00Z" "2026-03-02T04:00:01Z" "2026-03-02T04:00:02Z" "true" "manifest-sha"
  sentinel_state_mark_health_failure "$state_file"
  sentinel_state_ensure_incident "$state_file"

  sentinel_state_reset_incident "$state_file"

  assert_eq "0" "$(sentinel_state_get "$state_file" '.health.consecutive_failures' '9')" "reset incident should clear failures"
  assert_eq "null" "$(jq -r '.incident.id' "$state_file")" "reset incident should clear incident id"
  assert_eq "manifest-sha" "$(sentinel_state_get "$state_file" '.backup.last_manifest_sha' '')" "reset incident should not clear backup metadata"
)
pass "incident reset preserves backup snapshot"

# 8) apply updates remain atomic and leave no tmp files
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  sentinel_state_init "$state_file"

  i=1
  while [ "$i" -le 10 ]; do
    sentinel_state_mark_health_failure "$state_file"
    jq -e '.' "$state_file" >/dev/null
    i=$((i + 1))
  done

  assert_eq "10" "$(sentinel_state_get "$state_file" '.health.consecutive_failures' '0')" "all updates should persist"
  tmp_count="$(find "$tmp_root" -maxdepth 1 -name 'state.json.tmp.*' | wc -l | tr -d ' ')"
  assert_eq "0" "$tmp_count" "atomic writes should not leave temp files"
)
pass "state apply performs clean atomic writes"

bash -n "$STATE_LIB"
