#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY_LIB="$ROOT_DIR/scripts/lib/notify.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-notify-test
}

make_mock_bin() {
  local mock_bin="$1"

  cat > "$mock_bin/curl" <<'MOCKCURL'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${MOCK_CURL_ARGS_FILE:-}" ]; then
  printf '%s\n' "$@" >> "$MOCK_CURL_ARGS_FILE"
fi
if [ -n "${MOCK_CURL_STDIN_FILE:-}" ]; then
  cat > "$MOCK_CURL_STDIN_FILE"
fi
printf '{"ok":true}\n'
MOCKCURL
  chmod +x "$mock_bin/curl"
}

# 1) env bootstrap only imports allowed notification keys
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mkdir -p "$home_dir/.config/env" "$openclaw_home"

  cat > "$home_dir/.config/env/global.env" <<'EOFGLOBAL'
PATH=/tmp/poisoned
CUSTOM_NOTIFY_TOKEN=global-token
TELEGRAM_BOT_TOKEN_AVA=legacy-token
EOFGLOBAL

  cat > "$openclaw_home/.env" <<'EOFLOCAL'
CUSTOM_NOTIFY_TOKEN=local-token
EOFLOCAL

  # shellcheck disable=SC1090
  source "$NOTIFY_LIB"

  original_path="$PATH"
  unset CUSTOM_NOTIFY_TOKEN
  unset TELEGRAM_BOT_TOKEN_AVA

  HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" sentinel_notify_bootstrap_env "CUSTOM_NOTIFY_TOKEN"

  assert_eq "$original_path" "$PATH" "bootstrap should not import PATH from env files"
  assert_eq "local-token" "${CUSTOM_NOTIFY_TOKEN:-}" "bootstrap should import allowlisted custom token key"
  assert_eq "legacy-token" "${TELEGRAM_BOT_TOKEN_AVA:-}" "bootstrap should still load default telegram key"
)
pass "notify bootstrap uses env allowlist"

# 2) telegram send uses JSON payload and keeps token out of argv
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  args_file="$tmp_root/curl.args"
  stdin_file="$tmp_root/curl.stdin"
  mkdir -p "$mock_bin"
  : > "$args_file"
  : > "$stdin_file"
  make_mock_bin "$mock_bin"

  # shellcheck disable=SC1090
  source "$NOTIFY_LIB"
  PATH="$mock_bin:$PATH"

  export MOCK_CURL_ARGS_FILE="$args_file"
  export MOCK_CURL_STDIN_FILE="$stdin_file"

  sentinel_notify_init "NO_SUCH_ENV" "12345" ""
  SENTINEL_NOTIFY_TG_TOKEN="token-123"
  sentinel_notify_telegram 'Recovery at tier 1 & 2 = retry'

  if grep -q 'token-123' "$args_file"; then
    fail "telegram token must not appear in curl argv"
  fi
  grep -q 'token-123' "$stdin_file" || fail "telegram token should be present in curl config stdin"

  payload="$(awk 'prev=="-d"{print; exit} {prev=$0}' "$args_file")"
  [ -n "$payload" ] || fail "telegram payload should be passed via -d"
  assert_eq "12345" "$(jq -r '.chat_id' <<<"$payload")" "payload should include chat id"
  assert_eq 'Recovery at tier 1 & 2 = retry' "$(jq -r '.text' <<<"$payload")" "payload should preserve special characters"
)
pass "notify telegram uses protected token transport and JSON payload"

bash -n "$NOTIFY_LIB"
