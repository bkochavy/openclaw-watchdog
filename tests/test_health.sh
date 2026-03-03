#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH_LIB="$ROOT_DIR/scripts/lib/health.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-health-test
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
  mode="${MOCK_HEALTH_MODE:-ok_true}"
  if [ -n "${MOCK_HEALTH_SEQUENCE_FILE:-}" ] && [ -f "$MOCK_HEALTH_SEQUENCE_FILE" ]; then
    mode="$(head -n 1 "$MOCK_HEALTH_SEQUENCE_FILE")"
    tail -n +2 "$MOCK_HEALTH_SEQUENCE_FILE" > "$MOCK_HEALTH_SEQUENCE_FILE.next"
    mv "$MOCK_HEALTH_SEQUENCE_FILE.next" "$MOCK_HEALTH_SEQUENCE_FILE"
    [ -n "$mode" ] || mode="ok_true"
  fi

  case "$mode" in
    ok_true)
      echo '{"ok":true}'
      exit 0
      ;;
    ok_false)
      echo '{"ok":false}'
      exit 0
      ;;
    invalid_json)
      echo 'not-json'
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

echo '{}'
exit 0
MOCKCURL
  chmod +x "$mock_bin/curl"

  cat > "$mock_bin/openclaw" <<'MOCKOPENCLAW'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ge 3 ] && [ "$1" = "gateway" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
  status="${MOCK_OPENCLAW_STATUS_JSON:-}"
  if [ -z "$status" ]; then
    status='{"ok":false}'
  fi
  if [ -n "${MOCK_OPENCLAW_LOG:-}" ]; then
    printf 'gateway status --json\n' >> "$MOCK_OPENCLAW_LOG"
  fi
  echo "$status"
  exit "${MOCK_OPENCLAW_STATUS_EXIT:-0}"
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

# 1) Strict /healthz probe accepts only {"ok": true}
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin:$PATH"
  export MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz"
  export MOCK_HEALTH_MODE="ok_true"

  sentinel_health_probe "$MOCK_HEALTH_URL" 5
  assert_eq "healthz" "$SENTINEL_HEALTH_LAST_SOURCE" "health source should be healthz"
  assert_eq '{"ok":true}' "$SENTINEL_HEALTH_LAST_BODY" "health body should be recorded"
)
pass "strict healthz accepts ok true"

# 2) Strict /healthz probe rejects ok:false (no fallback success)
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin:$PATH"
  export MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz"
  export MOCK_HEALTH_MODE="ok_false"
  export MOCK_OPENCLAW_STATUS_JSON='{"ok":false}'

  if sentinel_health_probe "$MOCK_HEALTH_URL" 5; then
    fail "probe should fail when /healthz says ok:false and fallback is unhealthy"
  fi
)
pass "strict healthz rejects ok false"

# 3) Fallback succeeds when /healthz is unreachable and openclaw status reports ok
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin:$PATH"
  export MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz"
  export MOCK_HEALTH_MODE="fail"
  export MOCK_OPENCLAW_STATUS_JSON='{"ok":true}'

  sentinel_health_probe "$MOCK_HEALTH_URL" 5
  assert_eq "gateway-status" "$SENTINEL_HEALTH_LAST_SOURCE" "fallback source should be gateway-status"
  assert_eq '{"ok":true}' "$SENTINEL_HEALTH_LAST_BODY" "fallback body should be recorded"
)
pass "fallback uses openclaw status when healthz unreachable"

# 4) Fallback accepts healthy:true schema
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin:$PATH"
  export MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz"
  export MOCK_HEALTH_MODE="fail"
  export MOCK_OPENCLAW_STATUS_JSON='{"healthy":true}'

  sentinel_health_probe "$MOCK_HEALTH_URL" 5
  assert_eq "gateway-status" "$SENTINEL_HEALTH_LAST_SOURCE" "fallback should accept healthy:true"
)
pass "fallback accepts healthy true"

# 5) Fallback fails when openclaw command is missing
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/curl" <<'MOCKCURLONLY'
#!/usr/bin/env bash
set -euo pipefail
exit 7
MOCKCURLONLY
  chmod +x "$mock_bin/curl"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin"

  if sentinel_health_probe "http://127.0.0.1:18789/healthz" 5; then
    fail "probe should fail without openclaw fallback command"
  fi
)
pass "fallback fails without openclaw"

# 6) wait_for_ok requires all checks and sleeps between checks
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin:$PATH"

  seq_file="$tmp_root/health.seq"
  printf 'ok_true\nok_true\nok_true\n' > "$seq_file"
  curl_log="$tmp_root/curl.log"
  sleep_log="$tmp_root/sleep.log"
  : > "$curl_log"
  : > "$sleep_log"

  export MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz"
  export MOCK_HEALTH_SEQUENCE_FILE="$seq_file"
  export MOCK_CURL_LOG="$curl_log"
  export MOCK_SLEEP_LOG="$sleep_log"

  sentinel_health_wait_for_ok "$MOCK_HEALTH_URL" 3 2

  assert_eq "3" "$(wc -l < "$curl_log" | tr -d ' ')" "wait_for_ok should call health probe for each check"
  assert_eq "2" "$(wc -l < "$sleep_log" | tr -d ' ')" "wait_for_ok should sleep checks-1 times"
  assert_eq "2" "$(tail -n 1 "$sleep_log")" "sleep should use configured delay"
)
pass "wait_for_ok enforces repeated success"

# 7) wait_for_ok aborts on first failed probe
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  mkdir -p "$mock_bin"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$HEALTH_LIB"
  PATH="$mock_bin:$PATH"

  seq_file="$tmp_root/health.seq"
  printf 'fail\nok_true\nok_true\n' > "$seq_file"
  curl_log="$tmp_root/curl.log"
  sleep_log="$tmp_root/sleep.log"
  : > "$curl_log"
  : > "$sleep_log"

  export MOCK_HEALTH_URL="http://127.0.0.1:18789/healthz"
  export MOCK_HEALTH_SEQUENCE_FILE="$seq_file"
  export MOCK_CURL_LOG="$curl_log"
  export MOCK_SLEEP_LOG="$sleep_log"
  export MOCK_OPENCLAW_STATUS_JSON='{"ok":false}'

  if sentinel_health_wait_for_ok "$MOCK_HEALTH_URL" 3 2; then
    fail "wait_for_ok should fail fast when a check fails"
  fi

  assert_eq "1" "$(wc -l < "$curl_log" | tr -d ' ')" "wait_for_ok should stop probing after first failure"
  assert_eq "0" "$(wc -l < "$sleep_log" | tr -d ' ')" "wait_for_ok should not sleep after first failure"
)
pass "wait_for_ok fails fast"

bash -n "$HEALTH_LIB"
