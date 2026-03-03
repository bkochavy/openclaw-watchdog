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
  mktemp -d 2>/dev/null || mktemp -d -t openclaw-sentinel-flags-test
}

write_config() {
  local path="$1" state_file="$2" lock_file="$3" log_dir="$4" backup_enabled="$5" backup_schedule="$6" backup_system="$7" backup_memory="$8"
  cat > "$path" <<EOFCONFIG
{
  "health_url": "http://127.0.0.1:18789/healthz",
  "backup": {
    "enabled": $backup_enabled,
    "schedule": "$backup_schedule",
    "system_backup_dir": "$backup_system",
    "memory_backup_dir": "$backup_memory",
    "include_scripts": false,
    "include_skills": false,
    "include_launchd": false,
    "include_agents": false,
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
}

# 1) --status prints state JSON
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mkdir -p "$openclaw_home/state" "$openclaw_home/logs"

  config_file="$tmp_root/sentinel.json"
  state_file="$openclaw_home/state/sentinel-state.json"
  lock_file="$openclaw_home/state/sentinel.lock"
  log_dir="$openclaw_home/logs"
  write_config "$config_file" "$state_file" "$lock_file" "$log_dir" false "04:00" "$tmp_root/backups/system" "$tmp_root/backups/memory"

  out="$(HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" OPENCLAW_SENTINEL_CONFIG="$config_file" bash "$SENTINEL_SCRIPT" --status)"
  assert_eq "2" "$(jq -r '.version' <<<"$out")" "--status should output state JSON"
)
pass "sentinel --status outputs state"

# 2) --reset-incident clears failures and incident state
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mkdir -p "$openclaw_home/state" "$openclaw_home/logs"

  config_file="$tmp_root/sentinel.json"
  state_file="$openclaw_home/state/sentinel-state.json"
  lock_file="$openclaw_home/state/sentinel.lock"
  log_dir="$openclaw_home/logs"
  write_config "$config_file" "$state_file" "$lock_file" "$log_dir" false "04:00" "$tmp_root/backups/system" "$tmp_root/backups/memory"

  HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" OPENCLAW_SENTINEL_CONFIG="$config_file" bash "$SENTINEL_SCRIPT" --status >/dev/null
  jq '.health.consecutive_failures = 3 | .incident.id = "incident-1" | .health.current_incident_id = "incident-1" | .incident.tier_reached = 2' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" OPENCLAW_SENTINEL_CONFIG="$config_file" bash "$SENTINEL_SCRIPT" --reset-incident

  assert_eq "0" "$(jq -r '.health.consecutive_failures' "$state_file")" "--reset-incident should clear failures"
  assert_eq "null" "$(jq -r '.incident.id' "$state_file")" "--reset-incident should clear incident id"
)
pass "sentinel --reset-incident resets incident state"

# 3) --force-backup runs backup even when last backup is recent
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mkdir -p "$openclaw_home/state" "$openclaw_home/logs" "$openclaw_home/workspace/memory" "$openclaw_home/workspace"

  printf '{"ok":true}\n' > "$openclaw_home/openclaw.json"
  printf 'memory\n' > "$openclaw_home/workspace/MEMORY.md"

  config_file="$tmp_root/sentinel.json"
  state_file="$openclaw_home/state/sentinel-state.json"
  lock_file="$openclaw_home/state/sentinel.lock"
  log_dir="$openclaw_home/logs"
  backup_system_dir="$tmp_root/backups/system"
  backup_memory_dir="$tmp_root/backups/memory"
  write_config "$config_file" "$state_file" "$lock_file" "$log_dir" true "23:59" "$backup_system_dir" "$backup_memory_dir"

  HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" OPENCLAW_SENTINEL_CONFIG="$config_file" bash "$SENTINEL_SCRIPT" --status >/dev/null
  jq --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.backup.last_system_backup_at = $now' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" OPENCLAW_SENTINEL_CONFIG="$config_file" bash "$SENTINEL_SCRIPT" --backup-only --force-backup

  [ -f "$backup_system_dir/backup-manifest.txt" ] || fail "--force-backup should create backup manifest"
  assert_nonempty "$(jq -r '.backup.last_system_backup_at // empty' "$state_file")" "--force-backup should update backup snapshot"
)
pass "sentinel --force-backup bypasses schedule"

# 4) --migrate writes sentinel config from legacy watchdog/backup files
(
  tmp_root="$(mktemp_dir)"
  home_dir="$tmp_root/home"
  openclaw_home="$home_dir/.openclaw"
  mkdir -p "$openclaw_home/state" "$openclaw_home/logs"

  target_config="$tmp_root/sentinel.json"
  watchdog_file="$tmp_root/watchdog.json"
  backup_file="$tmp_root/backup.json"
  cat > "$watchdog_file" <<'EOFWD'
{"health_url":"http://127.0.0.1:29999/healthz","max_failures":6}
EOFWD
  cat > "$backup_file" <<'EOFBK'
{"backup_dir":"~/legacy-system"}
EOFBK

  HOME="$home_dir" OPENCLAW_HOME="$openclaw_home" OPENCLAW_SENTINEL_CONFIG="$target_config" OPENCLAW_WATCHDOG_CONFIG="$watchdog_file" OPENCLAW_BACKUP_CONFIG="$backup_file" bash "$SENTINEL_SCRIPT" --migrate --status >/dev/null

  [ -f "$target_config" ] || fail "--migrate should create sentinel config"
  assert_eq "http://127.0.0.1:29999/healthz" "$(jq -r '.health_url' "$target_config")" "migrated config should include legacy health_url"
  assert_eq "~/legacy-system" "$(jq -r '.backup.system_backup_dir' "$target_config")" "migrated config should include legacy backup_dir"
)
pass "sentinel --migrate writes merged config"

bash -n "$SENTINEL_SCRIPT"
