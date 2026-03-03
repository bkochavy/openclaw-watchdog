#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENTINEL_SCRIPT="$ROOT_DIR/scripts/sentinel.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-integration-test
}

make_mock_bin() {
  local mock_bin="$1"

  cat > "$mock_bin/curl" <<'MOCKCURL'
#!/usr/bin/env bash
set -euo pipefail

url=""
for arg in "$@"; do
  if [[ "$arg" == http* ]]; then
    url="$arg"
  fi
done

if [ -n "${MOCK_CURL_LOG:-}" ]; then
  printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
fi

if [ "$url" = "${MOCK_HEALTH_URL:-}" ]; then
  mode="${MOCK_HEALTH_MODE:-ok}"
  if [ -n "${MOCK_HEALTH_SEQUENCE_FILE:-}" ] && [ -f "$MOCK_HEALTH_SEQUENCE_FILE" ]; then
    mode="$(head -n 1 "$MOCK_HEALTH_SEQUENCE_FILE")"
    tail -n +2 "$MOCK_HEALTH_SEQUENCE_FILE" > "$MOCK_HEALTH_SEQUENCE_FILE.next"
    mv "$MOCK_HEALTH_SEQUENCE_FILE.next" "$MOCK_HEALTH_SEQUENCE_FILE"
    [ -n "$mode" ] || mode="ok"
  fi

  case "$mode" in
    ok)
      echo '{"ok":true}'
      exit 0
      ;;
    ok_false)
      echo '{"ok":false}'
      exit 0
      ;;
    fail)
      exit 7
      ;;
    *)
      echo '{}'
      exit 0
      ;;
  esac
fi

case "$url" in
  *"/sendMessage"|*"discord"*)
    echo '{"ok":true}'
    exit 0
    ;;
  *"/getUpdates")
    echo '{"result":[]}'
    exit 0
    ;;
esac

echo '{}'
exit 0
MOCKCURL
  chmod +x "$mock_bin/curl"

  cat > "$mock_bin/openclaw" <<'MOCKOPENCLAW'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${MOCK_OPENCLAW_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$MOCK_OPENCLAW_LOG"
fi

if [ "$#" -ge 3 ] && [ "$1" = "gateway" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
  status="${MOCK_GATEWAY_STATUS_JSON:-}"
  if [ -z "$status" ]; then
    status='{"ok":false}'
  fi
  echo "$status"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "gateway" ] && [ "$2" = "restart" ]; then
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "doctor" ] && [ "$2" = "--fix" ] && [ "$3" = "--non-interactive" ]; then
  exit 0
fi

exit 0
MOCKOPENCLAW
  chmod +x "$mock_bin/openclaw"

  cat > "$mock_bin/sleep" <<'MOCKSLEEP'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${MOCK_SLEEP_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$MOCK_SLEEP_LOG"
fi
exit 0
MOCKSLEEP
  chmod +x "$mock_bin/sleep"
}

# 1) Healthy path runs backup cycle and updates state snapshot
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin" "$openclaw_home/workspace/scripts" "$openclaw_home/workspace/memory" "$openclaw_home/workspace/life" "$openclaw_home/state" "$openclaw_home/logs"
  make_mock_bin "$mock_bin"

  printf '{"gateway":"config"}\n' > "$openclaw_home/openclaw.json"
  printf 'memory\n' > "$openclaw_home/workspace/MEMORY.md"
  printf 'script\n' > "$openclaw_home/workspace/scripts/example.sh"

  config_file="$tmp_root/sentinel.json"
  state_file="$openclaw_home/state/sentinel-state.json"
  lock_file="$openclaw_home/state/sentinel.lock"
  log_dir="$openclaw_home/logs"
  backup_system_dir="$tmp_root/backups/system"
  backup_memory_dir="$tmp_root/backups/memory"

  cat > "$config_file" <<EOFCONFIG
{
  "health_url": "http://127.0.0.1:18789/healthz",
  "recovery": {
    "max_failures_before_action": 2,
    "cooldown_seconds": 1800,
    "max_repairs_per_incident": 3
  },
  "backup": {
    "enabled": true,
    "schedule": "00:00",
    "system_backup_dir": "$backup_system_dir",
    "memory_backup_dir": "$backup_memory_dir",
    "include_scripts": true,
    "include_skills": false,
    "include_launchd": false,
    "include_agents": false,
    "redact_env_values": true,
    "max_backup_age_hours": 30,
    "critical_files": ["openclaw/openclaw.json"]
  },
  "notifications": {
    "telegram_bot_token_env": "NO_TOKEN",
    "telegram_chat_id": "",
    "discord_webhook_url": ""
  },
  "state_file": "$state_file",
  "lock_file": "$lock_file",
  "log_dir": "$log_dir"
}
EOFCONFIG

  export GIT_AUTHOR_NAME="sentinel-test"
  export GIT_AUTHOR_EMAIL="sentinel-test@example.com"
  export GIT_COMMITTER_NAME="sentinel-test"
  export GIT_COMMITTER_EMAIL="sentinel-test@example.com"

  openclaw_log="$tmp_root/openclaw.log"
  : > "$openclaw_log"

  HOME="$home_dir" \
  OPENCLAW_HOME="$openclaw_home" \
  OPENCLAW_SENTINEL_CONFIG="$config_file" \
  PATH="$mock_bin:$PATH" \
  MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz" \
  MOCK_HEALTH_MODE="ok" \
  MOCK_GATEWAY_STATUS_JSON='{"ok":false}' \
  MOCK_OPENCLAW_LOG="$openclaw_log" \
  bash "$SENTINEL_SCRIPT"

  [ -f "$backup_system_dir/backup-manifest.txt" ] || fail "healthy run should produce backup manifest"
  assert_nonempty "$(jq -r '.backup.last_system_backup_at // empty' "$state_file")" "healthy run should persist system backup timestamp"
  assert_eq "0" "$(jq -r '.health.consecutive_failures' "$state_file")" "healthy run should keep failure count at zero"
  assert_eq "0" "$(wc -l < "$openclaw_log" | tr -d ' ')" "healthy run should not invoke recovery commands"
)
pass "integration healthy path runs backup"

# 2) Unhealthy path escalates through deterministic recovery tiers
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin" "$openclaw_home/state" "$openclaw_home/logs"
  make_mock_bin "$mock_bin"

  config_file="$tmp_root/sentinel.json"
  state_file="$openclaw_home/state/sentinel-state.json"
  lock_file="$openclaw_home/state/sentinel.lock"
  log_dir="$openclaw_home/logs"

  cat > "$config_file" <<EOFCONFIG
{
  "health_url": "http://127.0.0.1:18789/healthz",
  "recovery": {
    "max_failures_before_action": 1,
    "cooldown_seconds": 1800,
    "max_repairs_per_incident": 3,
    "deterministic_restart_enabled": true,
    "deterministic_doctor_enabled": true,
    "config_rollback_enabled": false
  },
  "backup": {
    "enabled": false,
    "schedule": "00:00"
  },
  "notifications": {
    "telegram_bot_token_env": "NO_TOKEN",
    "telegram_chat_id": "",
    "discord_webhook_url": ""
  },
  "state_file": "$state_file",
  "lock_file": "$lock_file",
  "log_dir": "$log_dir"
}
EOFCONFIG

  health_seq="$tmp_root/health.seq"
  printf 'fail\nfail\nok\n' > "$health_seq"

  openclaw_log="$tmp_root/openclaw.log"
  sleep_log="$tmp_root/sleep.log"
  : > "$openclaw_log"
  : > "$sleep_log"

  HOME="$home_dir" \
  OPENCLAW_HOME="$openclaw_home" \
  OPENCLAW_SENTINEL_CONFIG="$config_file" \
  PATH="$mock_bin:$PATH" \
  MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz" \
  MOCK_HEALTH_SEQUENCE_FILE="$health_seq" \
  MOCK_GATEWAY_STATUS_JSON='{"ok":false}' \
  MOCK_OPENCLAW_LOG="$openclaw_log" \
  MOCK_SLEEP_LOG="$sleep_log" \
  bash "$SENTINEL_SCRIPT"

  assert_eq "0" "$(jq -r '.health.consecutive_failures' "$state_file")" "successful deterministic recovery should reset failures"
  assert_nonempty "$(jq -r '.health.last_healthy_at // empty' "$state_file")" "successful deterministic recovery should set last_healthy_at"
  assert_eq "2" "$(wc -l < "$sleep_log" | tr -d ' ')" "unhealthy deterministic tiers should wait between tier checks"

  sentinel_log_file="$log_dir/sentinel.log"
  grep -q 'tier 1 - gateway restart' "$sentinel_log_file" || fail "sentinel log should record tier 1 attempt"
  grep -q 'tier 2 - doctor fix' "$sentinel_log_file" || fail "sentinel log should record tier 2 attempt"
)
pass "integration unhealthy path triggers deterministic tiers"

bash -n "$SENTINEL_SCRIPT"
