#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_LIB="$ROOT_DIR/scripts/lib/config.sh"

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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-config-test
}

# 1) default config includes expected sentinel schema
(
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  default_json="$(sentinel_config_default_json)"

  assert_eq "http://127.0.0.1:18789/healthz" "$(jq -r '.health_url' <<<"$default_json")" "default health_url should use /healthz"
  assert_eq "true" "$(jq -r '.backup.enabled' <<<"$default_json")" "backup should be enabled by default"
  assert_eq "3" "$(jq -r '.recovery.max_repairs_per_incident' <<<"$default_json")" "max repairs default should match PRD"
)
pass "default config schema"

# 2) load uses defaults when no config files exist
(
  tmp_root="$(mktemp_dir)"
  export OPENCLAW_HOME="$tmp_root/openclaw-home"

  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  sentinel_config_load "$tmp_root/sentinel.json"

  assert_eq "default" "$SENTINEL_CONFIG_SOURCE" "config source should be default"
  assert_eq "$OPENCLAW_HOME/state/sentinel-state.json" "$(jq -r '.state_file' <<<"$SENTINEL_CONFIG_JSON")" "default state_file should be derived from OPENCLAW_HOME"
)
pass "config load defaults"

# 3) load merges explicit sentinel config over defaults
(
  tmp_root="$(mktemp_dir)"
  config_file="$tmp_root/sentinel.json"

  cat > "$config_file" <<'EOFSENTINEL'
{
  "health_url": "http://127.0.0.1:9999/healthz",
  "recovery": {
    "max_failures_before_action": 5,
    "deterministic_restart_enabled": false
  },
  "notifications": {
    "telegram_chat_id": "12345"
  }
}
EOFSENTINEL

  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  sentinel_config_load "$config_file"

  assert_eq "sentinel" "$SENTINEL_CONFIG_SOURCE" "config source should be sentinel"
  assert_eq "http://127.0.0.1:9999/healthz" "$(sentinel_config_get_string '.health_url' '')" "explicit health url should override default"
  assert_eq "5" "$(sentinel_config_get_int '.recovery.max_failures_before_action' 2)" "explicit recovery threshold should be used"
  assert_eq "false" "$(sentinel_config_get_bool '.recovery.deterministic_restart_enabled' true)" "bool overrides should be preserved"
  assert_eq "12345" "$(sentinel_config_get_string '.notifications.telegram_chat_id' '')" "chat id should load"
)
pass "config merge with sentinel file"

# 4) legacy config migration mapping loads when sentinel.json is absent
(
  tmp_root="$(mktemp_dir)"
  watchdog_file="$tmp_root/watchdog.json"
  backup_file="$tmp_root/backup.json"

  cat > "$watchdog_file" <<'EOFWD'
{
  "health_url": "http://127.0.0.1:7777/healthz",
  "telegram_bot_token_env": "TG_TOKEN_ENV",
  "telegram_chat_id": "9988",
  "max_failures": 4,
  "cooldown_seconds": 99,
  "max_repairs_per_incident": 9,
  "codex_timeout_seconds": 44,
  "rescue_command_timeout_seconds": 66,
  "rescue_command_prefix": "/rescue"
}
EOFWD

  cat > "$backup_file" <<'EOFBK'
{
  "backup_dir": "~/legacy-system",
  "memory_backup_dir": "~/legacy-memory",
  "github_repo": "sentinel-backups",
  "github_user": "openclaw",
  "max_backup_age_hours": 12,
  "critical_files": ["openclaw/openclaw.json"]
}
EOFBK

  export OPENCLAW_WATCHDOG_CONFIG="$watchdog_file"
  export OPENCLAW_BACKUP_CONFIG="$backup_file"

  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  sentinel_config_load "$tmp_root/missing-sentinel.json"

  assert_eq "legacy" "$SENTINEL_CONFIG_SOURCE" "config source should be legacy"
  assert_eq "http://127.0.0.1:7777/healthz" "$(sentinel_config_get_string '.health_url' '')" "legacy watchdog health url should migrate"
  assert_eq "4" "$(sentinel_config_get_int '.recovery.max_failures_before_action' 0)" "legacy max_failures should map"
  assert_eq "/rescue" "$(sentinel_config_get_string '.recovery.rescue_command_prefix' '')" "legacy rescue prefix should map"
  assert_eq "~/legacy-system" "$(sentinel_config_get_string '.backup.system_backup_dir' '')" "legacy backup dir should map"
)
pass "legacy config loads and maps fields"

# 5) migrate_legacy writes merged sentinel config file
(
  tmp_root="$(mktemp_dir)"
  watchdog_file="$tmp_root/watchdog.json"
  backup_file="$tmp_root/backup.json"
  target_file="$tmp_root/sentinel.json"

  cat > "$watchdog_file" <<'EOFWD'
{"health_url":"http://127.0.0.1:18888/healthz","max_failures":6}
EOFWD
  cat > "$backup_file" <<'EOFBK'
{"backup_dir":"~/merged-system"}
EOFBK

  export OPENCLAW_WATCHDOG_CONFIG="$watchdog_file"
  export OPENCLAW_BACKUP_CONFIG="$backup_file"

  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  sentinel_config_migrate_legacy "$target_file"

  [ -f "$target_file" ] || fail "migrated sentinel config should be written"
  assert_eq "http://127.0.0.1:18888/healthz" "$(jq -r '.health_url' "$target_file")" "migrated file should include watchdog fields"
  assert_eq "~/merged-system" "$(jq -r '.backup.system_backup_dir' "$target_file")" "migrated file should include backup fields"
)
pass "legacy migration writes sentinel config"

# 6) get helpers handle fallback and type conversion correctly
(
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  SENTINEL_CONFIG_JSON='{"name":"sentinel","count":"not-int","flag":"not-bool","path":"~/data"}'

  assert_eq "sentinel" "$(sentinel_config_get_string '.name' 'fallback')" "get_string should return value"
  assert_eq "fallback" "$(sentinel_config_get_string '.missing' 'fallback')" "get_string should fallback when missing"
  assert_eq "10" "$(sentinel_config_get_int '.count' 10)" "get_int should fallback on non-int"
  assert_eq "false" "$(sentinel_config_get_bool '.flag' false)" "get_bool should fallback on invalid bool"
  assert_eq "$HOME/data" "$(sentinel_config_get_path '.path' '~/fallback')" "get_path should expand ~"
)
pass "config helper getters"

# 7) config_write performs atomic write without temp file residue
(
  tmp_root="$(mktemp_dir)"
  target_file="$tmp_root/sentinel.json"

  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  sentinel_config_write "$target_file" '{"ok":true}'
  sentinel_config_write "$target_file" '{"ok":false}'

  assert_eq "false" "$(jq -r '.ok' "$target_file")" "final write should win"
  tmp_count="$(find "$tmp_root" -maxdepth 1 -name 'sentinel.json.tmp.*' | wc -l | tr -d ' ')"
  assert_eq "0" "$tmp_count" "atomic write should not leave temp files"
)
pass "config write atomic behavior"

bash -n "$CONFIG_LIB"
