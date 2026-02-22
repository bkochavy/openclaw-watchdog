#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG_SCRIPT="$ROOT_DIR/scripts/watchdog.sh"

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
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$message (expected='$expected' actual='$actual')"
  fi
}

mktemp_dir() {
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-watchdog-test
}

make_mock_curl() {
  local mock_bin="$1"
  cat > "$mock_bin/curl" <<'CURLMOCK'
#!/usr/bin/env bash
set -uo pipefail

url=""
prev=""
for arg in "$@"; do
  if [[ "$arg" == http* ]]; then
    url="$arg"
  fi
  if [ "$prev" = "-d" ] && [ -n "${MOCK_CURL_LOG:-}" ]; then
    printf '%s\n' "$arg" >> "$MOCK_CURL_LOG"
  fi
  prev="$arg"
done

if [ -n "${MOCK_CURL_LOG:-}" ]; then
  printf 'URL=%s ARGS=%s\n' "$url" "$*" >> "$MOCK_CURL_LOG"
fi

if [ "$url" = "${MOCK_HEALTH_URL:-}" ]; then
  if [ "${MOCK_HEALTH:-fail}" = "ok" ]; then
    echo "ok"
    exit 0
  fi
  exit 7
fi

case "$url" in
  *"/sendMessage")
    echo '{"ok":true}'
    exit 0
    ;;
  *"/getUpdates")
    echo '{"result":[]}'
    exit 0
    ;;
  *)
    echo '{}'
    exit 0
    ;;
esac
CURLMOCK
  chmod +x "$mock_bin/curl"

  cat > "$mock_bin/codex" <<'CODEXMOCK'
#!/usr/bin/env bash
echo "mock codex"
exit 0
CODEXMOCK
  chmod +x "$mock_bin/codex"
}

write_config() {
  local path="$1"
  local health_url="$2"
  local state_file="$3"
  local lock_file="$4"
  local max_failures="$5"
  local cooldown="$6"

  cat > "$path" <<EOFCONF
{
  "health_url": "$health_url",
  "telegram_bot_token_env": "TEST_TOKEN_ENV",
  "telegram_chat_id": "12345",
  "max_failures": $max_failures,
  "cooldown_seconds": $cooldown,
  "max_repairs_per_incident": 3,
  "codex_timeout_seconds": 180,
  "rescue_command_timeout_seconds": 420,
  "rescue_command_prefix": "/codex",
  "recovery_log": "~/.openclaw/workspace/memory/recovery-log.md",
  "state_file": "$state_file",
  "lock_file": "$lock_file",
  "codex_model": "gpt-5.3-codex",
  "codex_bin": "",
  "claude_bin": ""
}
EOFCONF
}

run_watchdog() {
  local home_dir="$1"
  local config_path="$2"
  local path_prefix="$3"
  local tmp_dir="$4"

  OPENCLAW_HOME="$home_dir" \
  OPENCLAW_WATCHDOG_CONFIG="$config_path" \
  PATH="$path_prefix:$PATH" \
  TMPDIR="$tmp_dir" \
  TEST_TOKEN_ENV="token-123" \
  "$WATCHDOG_SCRIPT" >/dev/null 2>&1
}

# 1) Config loading: missing config falls back to defaults
(
  tmp_root="$(mktemp_dir)"
  HOME="$tmp_root/home"
  mkdir -p "$HOME"

  OPENCLAW_HOME="$HOME/.openclaw" OPENCLAW_WATCHDOG_CONFIG="$tmp_root/missing.json" WATCHDOG_SKIP_MAIN=1 \
    bash -c 'source "$1"; load_config; [ "$HEALTH_URL" = "http://127.0.0.1:18789" ] && [ "$MAX_FAILURES" -eq 2 ] && [ "$STATE_FILE" = "/tmp/openclaw-watchdog-state" ]' _ "$WATCHDOG_SCRIPT"
)
pass "config loading defaults"

# 2) State file read/write cycle
(
  tmp_root="$(mktemp_dir)"
  state_file="$tmp_root/state"

  WATCHDOG_SKIP_MAIN=1 bash -c 'source "$1"; STATE_FILE="$2"; FAILURES=2; LAST_REPAIR=11; REPAIRS_THIS_INCIDENT=3; RESCUE_ANNOUNCED=1; write_state; FAILURES=0; LAST_REPAIR=0; REPAIRS_THIS_INCIDENT=0; RESCUE_ANNOUNCED=0; read_state; [ "$FAILURES" -eq 2 ] && [ "$LAST_REPAIR" -eq 11 ] && [ "$REPAIRS_THIS_INCIDENT" -eq 3 ] && [ "$RESCUE_ANNOUNCED" -eq 1 ]' _ "$WATCHDOG_SCRIPT" "$state_file"
)
pass "state file read/write cycle"

# 3) Lock file prevents overlapping runs
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  mkdir -p "$home_dir"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_curl "$mock_bin"

  config="$tmp_root/watchdog.json"
  state_file="$tmp_root/state"
  lock_file="$tmp_root/lock"
  write_config "$config" "http://127.0.0.1:18789" "$state_file" "$lock_file" 2 1800

  echo $$ > "$lock_file"
  run_watchdog "$home_dir/.openclaw" "$config" "$mock_bin" "$tmp_root/tmp"

  grep -q "Another watchdog run is active" "$home_dir/.openclaw/logs/watchdog.log"
)
pass "lock file overlap prevention"

# 4) Health check success keeps FAILURES at 0
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  mkdir -p "$home_dir"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_curl "$mock_bin"

  config="$tmp_root/watchdog.json"
  state_file="$tmp_root/state"
  lock_file="$tmp_root/lock"
  write_config "$config" "http://127.0.0.1:18789" "$state_file" "$lock_file" 2 1800
  cat > "$state_file" <<'STATEEOF'
FAILURES=3
LAST_REPAIR=0
REPAIRS_THIS_INCIDENT=0
RESCUE_ANNOUNCED=0
STATEEOF

  MOCK_HEALTH_URL="http://127.0.0.1:18789" MOCK_HEALTH="ok" run_watchdog "$home_dir/.openclaw" "$config" "$mock_bin" "$tmp_root/tmp"

  # shellcheck disable=SC1090
  source "$state_file"
  assert_eq "0" "$FAILURES" "FAILURES should reset to 0 after healthy check"
)
pass "health success resets failures"

# 5) Health check failure increments FAILURES
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  mkdir -p "$home_dir"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_curl "$mock_bin"

  config="$tmp_root/watchdog.json"
  state_file="$tmp_root/state"
  lock_file="$tmp_root/lock"
  write_config "$config" "http://127.0.0.1:18789" "$state_file" "$lock_file" 5 1800

  cat > "$state_file" <<'STATEEOF'
FAILURES=0
LAST_REPAIR=0
REPAIRS_THIS_INCIDENT=0
RESCUE_ANNOUNCED=0
STATEEOF

  MOCK_HEALTH_URL="http://127.0.0.1:18789" MOCK_HEALTH="fail" run_watchdog "$home_dir/.openclaw" "$config" "$mock_bin" "$tmp_root/tmp"

  # shellcheck disable=SC1090
  source "$state_file"
  assert_eq "1" "$FAILURES" "FAILURES should increment on health failure"
)
pass "health failure increments failures"

# 6) Failure threshold triggers notification call
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  mkdir -p "$home_dir"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_curl "$mock_bin"

  config="$tmp_root/watchdog.json"
  state_file="$tmp_root/state"
  lock_file="$tmp_root/lock"
  write_config "$config" "http://127.0.0.1:18789" "$state_file" "$lock_file" 2 3600

  now_epoch="$(date +%s)"
  cat > "$state_file" <<EOFSTATE
FAILURES=1
LAST_REPAIR=$now_epoch
REPAIRS_THIS_INCIDENT=0
RESCUE_ANNOUNCED=0
EOFSTATE

  curl_log="$tmp_root/curl.log"
  MOCK_CURL_LOG="$curl_log" MOCK_HEALTH_URL="http://127.0.0.1:18789" MOCK_HEALTH="fail" run_watchdog "$home_dir/.openclaw" "$config" "$mock_bin" "$tmp_root/tmp"

  grep -q "Gateway down for ~10 minutes" "$curl_log"
  grep -q "chat_id=12345" "$curl_log"
)
pass "threshold notification call"

# 7) Syntax check
bash -n "$WATCHDOG_SCRIPT"
pass "watchdog syntax check"

printf '\nAll tests passed (%d checks).\n' "$PASS_COUNT"
