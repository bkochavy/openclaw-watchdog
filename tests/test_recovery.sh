#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_LIB="$ROOT_DIR/scripts/lib/state.sh"
RECOVERY_LIB="$ROOT_DIR/scripts/lib/recovery.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-recovery-test
}

# 1) agent resolution prefers explicit codex binary
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"

  codex_explicit="$tmp_root/codex-explicit"
  claude_explicit="$tmp_root/claude-explicit"
  codex_path_bin="$mock_bin/codex"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$codex_explicit"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$claude_explicit"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$codex_path_bin"
  chmod +x "$codex_explicit" "$claude_explicit" "$codex_path_bin"

  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"
  PATH="$mock_bin:$PATH"
  RECOVERY_CODEX_BIN="$codex_explicit"
  RECOVERY_CLAUDE_BIN="$claude_explicit"

  assert_eq "codex:$codex_explicit" "$(sentinel_recovery_resolve_agent)" "explicit codex binary should win"
)
pass "agent resolution prefers explicit codex"

# 2) agent resolution falls back to claude when codex is unavailable
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"

  claude_path_bin="$mock_bin/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$claude_path_bin"
  chmod +x "$claude_path_bin"

  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"
  PATH="$mock_bin"
  RECOVERY_CODEX_BIN=""
  RECOVERY_CLAUDE_BIN=""

  assert_eq "claude:$claude_path_bin" "$(sentinel_recovery_resolve_agent)" "claude should be selected when codex is absent"
)
pass "agent resolution falls back to claude"

# 3) recovery run escalates tier 1 -> tier 2 and marks incident healthy on success
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"
  calls_log="$tmp_root/calls.log"
  notify_log="$tmp_root/notify.log"
  : > "$calls_log"
  : > "$notify_log"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"

  STATE_FILE="$state_file"
  LOG_DIR="$tmp_root/logs"
  HEALTH_URL="http://127.0.0.1:18789/healthz"
  OPENCLAW_HOME="$tmp_root/openclaw"
  BACKUP_SYSTEM_DIR="$tmp_root/backups/system"
  SENTINEL_BACKUP_LAST_MANIFEST_SHA=""

  RECOVERY_MAX_FAILURES=2
  RECOVERY_COOLDOWN_SECONDS=1800
  RECOVERY_MAX_REPAIRS=3
  RECOVERY_RESTART_ENABLED=true
  RECOVERY_DOCTOR_ENABLED=true
  RECOVERY_ROLLBACK_ENABLED=true

  sentinel_log() { printf '%s\n' "$1" >> "$tmp_root/sentinel.log"; }
  sentinel_notify_send() { printf '%s\n' "$1" >> "$notify_log"; }
  sentinel_backup_ensure_recent_for_repair() { return 0; }
  sentinel_tg_prime_offset() { :; }
  sentinel_tg_fetch_prefixed_command() { return 1; }
  sentinel_health_probe() { return 1; }

  sentinel_recovery_try_deterministic() {
    printf '%s\n' "$1" >> "$calls_log"
    if [ "$1" = "2" ]; then
      return 0
    fi
    return 1
  }
  sentinel_recovery_try_rollback() { printf 'rollback\n' >> "$calls_log"; return 1; }
  sentinel_recovery_try_agent() { printf 'agent\n' >> "$calls_log"; return 1; }
  sentinel_recovery_rescue_mode() { printf 'rescue\n' >> "$calls_log"; return 0; }

  sentinel_state_init "$STATE_FILE"
  sentinel_state_mark_health_failure "$STATE_FILE"
  sentinel_state_mark_health_failure "$STATE_FILE"

  sentinel_recovery_run

  assert_eq "1,2" "$(paste -sd, "$calls_log")" "recovery should attempt tier 1 then tier 2"
  assert_eq "0" "$(sentinel_state_get "$STATE_FILE" '.health.consecutive_failures' '9')" "successful recovery should reset failures"
  assert_eq "null" "$(jq -r '.incident.id' "$STATE_FILE")" "successful recovery should close incident"
  grep -q 'tier 2' "$notify_log" || fail "tier 2 recovery notification should be sent"
)
pass "recovery escalates and succeeds at tier 2"

# 4) cooldown blocks additional tier 4+ attempts
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"
  calls_log="$tmp_root/calls.log"
  log_file="$tmp_root/sentinel.log"
  : > "$calls_log"
  : > "$log_file"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"

  STATE_FILE="$state_file"
  HEALTH_URL="http://127.0.0.1:18789/healthz"
  LOG_DIR="$tmp_root/logs"
  OPENCLAW_HOME="$tmp_root/openclaw"
  BACKUP_SYSTEM_DIR="$tmp_root/backups/system"

  RECOVERY_MAX_FAILURES=1
  RECOVERY_COOLDOWN_SECONDS=3600
  RECOVERY_MAX_REPAIRS=5
  RECOVERY_RESTART_ENABLED=true
  RECOVERY_DOCTOR_ENABLED=true
  RECOVERY_ROLLBACK_ENABLED=true

  sentinel_log() { printf '%s\n' "$1" >> "$log_file"; }
  sentinel_notify_send() { :; }
  sentinel_backup_ensure_recent_for_repair() { return 0; }
  sentinel_tg_prime_offset() { :; }
  sentinel_tg_fetch_prefixed_command() { return 1; }
  sentinel_health_probe() { return 1; }

  sentinel_recovery_try_deterministic() { printf 'deterministic\n' >> "$calls_log"; return 1; }
  sentinel_recovery_try_rollback() { printf 'rollback\n' >> "$calls_log"; return 1; }
  sentinel_recovery_try_agent() { printf 'agent\n' >> "$calls_log"; return 1; }
  sentinel_recovery_rescue_mode() { printf 'rescue\n' >> "$calls_log"; return 0; }

  sentinel_state_init "$STATE_FILE"
  sentinel_state_mark_health_failure "$STATE_FILE"
  sentinel_state_ensure_incident "$STATE_FILE"
  sentinel_state_set_tier "$STATE_FILE" 4
  sentinel_state_increment_repairs "$STATE_FILE"

  sentinel_recovery_run

  assert_eq "0" "$(wc -l < "$calls_log" | tr -d ' ')" "cooldown should block repair attempts"
  grep -q 'cooldown active' "$log_file" || fail "cooldown log should be emitted"
)
pass "recovery cooldown prevents repeated attempts"

# 5) max repairs switches to rescue mode (tier 5)
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"
  rescue_log="$tmp_root/rescue.log"
  : > "$rescue_log"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"

  STATE_FILE="$state_file"
  HEALTH_URL="http://127.0.0.1:18789/healthz"
  LOG_DIR="$tmp_root/logs"
  OPENCLAW_HOME="$tmp_root/openclaw"
  BACKUP_SYSTEM_DIR="$tmp_root/backups/system"

  RECOVERY_MAX_FAILURES=1
  RECOVERY_COOLDOWN_SECONDS=10
  RECOVERY_MAX_REPAIRS=3
  RECOVERY_RESTART_ENABLED=true
  RECOVERY_DOCTOR_ENABLED=true
  RECOVERY_ROLLBACK_ENABLED=true

  sentinel_log() { :; }
  sentinel_notify_send() { :; }
  sentinel_backup_ensure_recent_for_repair() { return 0; }
  sentinel_tg_prime_offset() { :; }
  sentinel_tg_fetch_prefixed_command() { return 1; }
  sentinel_health_probe() { return 1; }

  sentinel_recovery_try_deterministic() { fail "deterministic tiers should not run after max repairs reached"; }
  sentinel_recovery_try_rollback() { fail "rollback tier should not run after max repairs reached"; }
  sentinel_recovery_try_agent() { fail "agent tier should not run after max repairs reached"; }
  sentinel_recovery_rescue_mode() { printf 'rescue\n' >> "$rescue_log"; return 0; }

  sentinel_state_init "$STATE_FILE"
  sentinel_state_mark_health_failure "$STATE_FILE"
  sentinel_state_ensure_incident "$STATE_FILE"
  sentinel_state_apply "$STATE_FILE" '.incident.repairs_attempted = 3 | .incident.last_repair_at = "2026-03-02T00:00:00Z"'

  sentinel_recovery_run

  assert_eq "5" "$(sentinel_state_get "$STATE_FILE" '.incident.tier_reached' '0')" "tier should move to rescue tier 5"
  assert_eq "1" "$(wc -l < "$rescue_log" | tr -d ' ')" "rescue mode should be invoked once"
)
pass "max repairs triggers rescue mode"

# 6) coding agent execution enforces configured timeout
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  timeout_log="$tmp_root/timeout.log"
  codex_log="$tmp_root/codex.log"
  : > "$timeout_log"
  : > "$codex_log"

  cat > "$mock_bin/timeout" <<'EOFTIMEOUT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_TIMEOUT_LOG"
seconds="$1"
shift
[ -n "$seconds" ]
"$@"
EOFTIMEOUT
  chmod +x "$mock_bin/timeout"

  cat > "$mock_bin/codex" <<'EOFCODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CODEX_LOG"
exit 0
EOFCODEX
  chmod +x "$mock_bin/codex"

  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"
  PATH="$mock_bin:$PATH"
  export MOCK_TIMEOUT_LOG="$timeout_log"
  export MOCK_CODEX_LOG="$codex_log"
  RECOVERY_CODEX_BIN=""
  RECOVERY_CLAUDE_BIN=""
  RECOVERY_CODEX_MODEL="test-model"

  sentinel_recovery_run_agent 17 "repair now"

  grep -q '^17 ' "$timeout_log" || fail "timeout wrapper should receive configured timeout seconds"
  grep -q -- '--dangerously-bypass-approvals-and-sandbox --model test-model repair now' "$codex_log" || fail "codex invocation should include model and prompt"
)
pass "agent execution applies timeout"

# 7) deterministic tiers increment repairs_attempted
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state.json"

  # shellcheck disable=SC1090
  source "$STATE_LIB"
  # shellcheck disable=SC1090
  source "$RECOVERY_LIB"

  STATE_FILE="$state_file"
  HEALTH_URL="http://127.0.0.1:18789/healthz"

  sentinel_state_init "$STATE_FILE"
  sentinel_state_ensure_incident "$STATE_FILE"
  sentinel_recovery_exec() { return 1; }
  sentinel_recovery_wait_check() { return 1; }

  sentinel_recovery_try_deterministic 1 "gateway restart" openclaw gateway restart || true

  assert_eq "1" "$(sentinel_state_get "$STATE_FILE" '.incident.tier_reached' '0')" "deterministic tier should set tier"
  assert_eq "1" "$(sentinel_state_get "$STATE_FILE" '.incident.repairs_attempted' '0')" "deterministic tier should increment repairs"
)
pass "deterministic tiers increment repairs"

bash -n "$RECOVERY_LIB"
