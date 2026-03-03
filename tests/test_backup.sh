#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_LIB="$ROOT_DIR/scripts/lib/backup.sh"

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

mktemp_dir() {
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-backup-test
}

# 1) backup schedule can be forced regardless of timestamp
(
  # shellcheck disable=SC1090
  source "$BACKUP_LIB"
  sentinel_backup_should_run "23:59" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" 1
)
pass "backup should_run respects force flag"

# 2) backup schedule runs when last backup is missing
(
  # shellcheck disable=SC1090
  source "$BACKUP_LIB"
  sentinel_backup_should_run "00:00" "" 0
)
pass "backup should_run when no previous backup exists"

# 3) backup schedule skips when already backed up after today's schedule
(
  # shellcheck disable=SC1090
  source "$BACKUP_LIB"
  if sentinel_backup_should_run "00:00" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" 0; then
    fail "backup should skip when backup already ran today"
  fi
)
pass "backup should_run skips recent run"

# 4) manifest generation includes file counts and critical status
(
  tmp_root="$(mktemp_dir)"
  backup_dir="$tmp_root/system"
  mkdir -p \
    "$backup_dir/openclaw" \
    "$backup_dir/agents" \
    "$backup_dir/workspace-config" \
    "$backup_dir/skills" \
    "$backup_dir/scripts" \
    "$backup_dir/launchd" \
    "$backup_dir/cron" \
    "$backup_dir/identity" \
    "$backup_dir/credentials"
  printf '{"ok":true}\n' > "$backup_dir/openclaw/openclaw.json"

  # shellcheck disable=SC1090
  source "$BACKUP_LIB"
  sentinel_backup_generate_manifest "$backup_dir" "2026-03-02" $'openclaw/openclaw.json\nworkspace-config/AGENTS.md'

  manifest="$backup_dir/backup-manifest.txt"
  [ -f "$manifest" ] || fail "manifest should be generated"
  grep -q 'openclaw: 1 files' "$manifest" || fail "manifest should count openclaw files"
  grep -q 'OK' "$manifest" || fail "manifest should mark existing critical file as OK"
  grep -q 'MISSING workspace-config/AGENTS.md' "$manifest" || fail "manifest should mark missing critical files"
)
pass "manifest generation reports critical files"

# 5) backup health check deduplicates stale manifest alerts
(
  tmp_root="$(mktemp_dir)"

  # shellcheck disable=SC1090
  source "$BACKUP_LIB"

  BACKUP_SYSTEM_DIR="$tmp_root/system"
  BACKUP_MAX_AGE_HOURS=30
  STATE_FILE="$tmp_root/state.json"
  notify_log="$tmp_root/notify.log"
  : > "$notify_log"
  LAST_ALERT_KEY=""

  sentinel_notify_send() { printf '%s\n' "$1" >> "$notify_log"; }
  sentinel_state_get() { printf '%s\n' "$LAST_ALERT_KEY"; }
  sentinel_state_set_backup_alert_key() { LAST_ALERT_KEY="$2"; }

  mkdir -p "$BACKUP_SYSTEM_DIR"

  sentinel_backup_health_check
  sentinel_backup_health_check

  assert_eq "1" "$(wc -l < "$notify_log" | tr -d ' ')" "duplicate stale-manifest alerts should be suppressed"
  [ -n "$LAST_ALERT_KEY" ] || fail "dedup key should be stored after failure"
)
pass "backup health check deduplicates alerts"

# 6) backup health check clears dedup key when manifest is fresh
(
  tmp_root="$(mktemp_dir)"

  # shellcheck disable=SC1090
  source "$BACKUP_LIB"

  BACKUP_SYSTEM_DIR="$tmp_root/system"
  BACKUP_MAX_AGE_HOURS=30
  STATE_FILE="$tmp_root/state.json"
  LAST_ALERT_KEY="old-dedup-key"

  sentinel_notify_send() { :; }
  sentinel_state_get() { printf '%s\n' "$LAST_ALERT_KEY"; }
  sentinel_state_set_backup_alert_key() { LAST_ALERT_KEY="$2"; }

  mkdir -p "$BACKUP_SYSTEM_DIR"
  printf 'manifest\n' > "$BACKUP_SYSTEM_DIR/backup-manifest.txt"

  sentinel_backup_health_check

  assert_eq "" "$LAST_ALERT_KEY" "fresh manifest should clear dedup key"
)
pass "backup health check clears dedup state when healthy"

# 7) run_cycle updates backup snapshot when schedule is due
(
  tmp_root="$(mktemp_dir)"

  # shellcheck disable=SC1090
  source "$BACKUP_LIB"

  STATE_FILE="$tmp_root/state.json"
  BACKUP_ENABLED=true
  BACKUP_SCHEDULE="00:00"
  OPENCLAW_HOME="$tmp_root/openclaw"
  BACKUP_MEMORY_DIR="$tmp_root/memory"

  system_log="$tmp_root/system.log"
  memory_log="$tmp_root/memory.log"
  snapshot_log="$tmp_root/snapshot.log"
  : > "$system_log"
  : > "$memory_log"
  : > "$snapshot_log"

  sentinel_state_get() { printf '%s\n' ''; }
  sentinel_state_set_backup_snapshot() { printf '%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "$6" >> "$snapshot_log"; }
  sentinel_backup_health_check() { :; }

  sentinel_backup_run_system() {
    printf 'system\n' >> "$system_log"
    SENTINEL_BACKUP_LAST_SYSTEM_AT="2026-03-02T04:00:00Z"
    SENTINEL_BACKUP_LAST_PUSH_AT="2026-03-02T04:00:05Z"
    SENTINEL_BACKUP_LAST_PUSH_VERIFIED="true"
    SENTINEL_BACKUP_LAST_MANIFEST_SHA="manifest-sha"
  }

  sentinel_backup_memory_run() {
    printf 'memory\n' >> "$memory_log"
    return 0
  }

  sentinel_backup_run_cycle 0

  assert_eq "1" "$(wc -l < "$system_log" | tr -d ' ')" "run_cycle should execute system backup"
  assert_eq "1" "$(wc -l < "$memory_log" | tr -d ' ')" "run_cycle should execute memory backup"
  assert_eq "1" "$(wc -l < "$snapshot_log" | tr -d ' ')" "run_cycle should persist backup snapshot"
)
pass "backup run_cycle executes due backup and snapshot"

bash -n "$BACKUP_LIB"
