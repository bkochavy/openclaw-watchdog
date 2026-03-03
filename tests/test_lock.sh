#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_LIB="$ROOT_DIR/scripts/lib/lock.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-lock-test
}

# 1) lock acquire writes JSON lock file
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_acquire "$lock_file" 900

  [ -f "$lock_file" ] || fail "lock file should exist"
  assert_eq "$$" "$(jq -r '.pid' "$lock_file")" "lock pid should match current process"
  [ -n "$(jq -r '.created_at' "$lock_file")" ] || fail "created_at should be populated"
)
pass "lock acquire writes lock file"

# 2) lock acquire fails while fresh lock is active
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_acquire "$lock_file" 900

  if sentinel_lock_acquire "$lock_file" 900; then
    fail "acquire should fail when active lock exists"
  fi
)
pass "lock acquire blocks overlapping run"

# 3) release removes lock file
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_acquire "$lock_file" 900
  sentinel_lock_release "$lock_file"

  [ ! -f "$lock_file" ] || fail "lock file should be removed"
)
pass "lock release removes file"

# 4) stale detection returns true for dead PID
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  cat > "$lock_file" <<'EOFLOCK'
{"pid":999999,"created_at":"2026-03-02T00:00:00Z","hostname":"test"}
EOFLOCK

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_is_stale "$lock_file" 900
)
pass "dead pid lock is stale"

# 5) stale detection returns true for very old lock even if PID is alive
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  cat > "$lock_file" <<EOFLOCK
{"pid":$$,"created_at":"2000-01-01T00:00:00Z","hostname":"test"}
EOFLOCK

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_is_stale "$lock_file" 900
)
pass "old lock is stale even with live pid"

# 6) fresh lock with live PID is not stale
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "$lock_file" <<EOFLOCK
{"pid":$$,"created_at":"$now_iso","hostname":"test"}
EOFLOCK

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  if sentinel_lock_is_stale "$lock_file" 900; then
    fail "fresh active lock should not be stale"
  fi
)
pass "fresh active lock is not stale"

# 7) acquire replaces stale lock file
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  cat > "$lock_file" <<'EOFLOCK'
{"pid":999999,"created_at":"2000-01-01T00:00:00Z","hostname":"old-host"}
EOFLOCK

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_acquire "$lock_file" 900

  assert_eq "$$" "$(jq -r '.pid' "$lock_file")" "stale lock should be replaced with current pid"
)
pass "acquire replaces stale lock"

# 8) PID helper validates live and invalid pids
(
  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_is_pid_alive "$$"
  if sentinel_lock_is_pid_alive "not-a-pid"; then
    fail "non-numeric pid should not be treated as alive"
  fi
)
pass "pid alive helper validates input"

# 9) lock acquisition remains atomic under concurrent contention
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"
  acquired_log="$tmp_root/acquired.log"
  : > "$acquired_log"

  i=1
  while [ "$i" -le 20 ]; do
    bash -c 'source "$1"; if sentinel_lock_acquire "$2" 900; then echo "$$" >> "$3"; sleep 1; fi' _ "$LOCK_LIB" "$lock_file" "$acquired_log" &
    i=$((i + 1))
  done
  wait

  assert_eq "1" "$(wc -l < "$acquired_log" | tr -d ' ')" "exactly one contender should acquire the lock"
)
pass "lock acquire is atomic under contention"

# 10) release does not delete a lock owned by another process
(
  tmp_root="$(mktemp_dir)"
  lock_file="$tmp_root/sentinel.lock"

  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  sentinel_lock_acquire "$lock_file" 900

  bash -c 'source "$1"; sentinel_lock_release "$2"' _ "$LOCK_LIB" "$lock_file"
  [ -f "$lock_file" ] || fail "non-owner release should not remove lock"
)
pass "lock release preserves non-owner lock"

bash -n "$LOCK_LIB"
