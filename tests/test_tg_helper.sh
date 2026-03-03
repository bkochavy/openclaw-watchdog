#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TG_HELPER_LIB="$ROOT_DIR/scripts/lib/tg-helper.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-tg-helper-test
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
printf '%s\n' "${MOCK_CURL_RESPONSE:-{\"result\":[]}}"
MOCKCURL
  chmod +x "$mock_bin/curl"
}

# 1) tg_send uses JSON payload and keeps token out of argv
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
  source "$TG_HELPER_LIB"
  PATH="$mock_bin:$PATH"

  export MOCK_CURL_ARGS_FILE="$args_file"
  export MOCK_CURL_STDIN_FILE="$stdin_file"
  export MOCK_CURL_RESPONSE='{"ok":true}'

  sentinel_tg_send "tg-token-abc" "555" "--suffix" 'A & B = C'

  if grep -q 'tg-token-abc' "$args_file"; then
    fail "tg token must not appear in curl argv"
  fi
  grep -q 'tg-token-abc' "$stdin_file" || fail "tg token should be present in curl config stdin"

  payload="$(awk 'prev=="-d"{print; exit} {prev=$0}' "$args_file")"
  [ -n "$payload" ] || fail "send payload should be passed through -d"
  assert_eq "555" "$(jq -r '.chat_id' <<<"$payload")" "payload should include chat id"
  assert_eq $'A & B = C\n--suffix' "$(jq -r '.text' <<<"$payload")" "suffix should be appended once and special chars preserved"
)
pass "tg_send protects token and preserves payload"

# 2) fetch_prefixed_command extracts latest matching command and advances offset
(
  tmp_root="$(mktemp_dir)"
  mock_bin="$tmp_root/bin"
  args_file="$tmp_root/curl.args"
  stdin_file="$tmp_root/curl.stdin"
  offset_file="$tmp_root/offset"
  mkdir -p "$mock_bin"
  : > "$args_file"
  : > "$stdin_file"
  make_mock_bin "$mock_bin"
  printf '10\n' > "$offset_file"

  export MOCK_CURL_ARGS_FILE="$args_file"
  export MOCK_CURL_STDIN_FILE="$stdin_file"
  export MOCK_CURL_RESPONSE='{"result":[{"update_id":11,"message":{"chat":{"id":777},"text":"/codex noop"}},{"update_id":12,"message":{"chat":{"id":555},"text":"/codex restart gateway"}}]}'

  # shellcheck disable=SC1090
  source "$TG_HELPER_LIB"
  PATH="$mock_bin:$PATH"

  cmd="$(sentinel_tg_fetch_prefixed_command "tg-token-abc" "555" "/codex" "$offset_file")"

  assert_eq "restart gateway" "$cmd" "fetch should return latest matching prefixed command"
  assert_eq "13" "$(cat "$offset_file")" "offset should advance beyond latest update id"
)
pass "fetch_prefixed_command parses updates and advances offset"

bash -n "$TG_HELPER_LIB"
