#!/usr/bin/env bash

set -euo pipefail

if [ "$(uname -s)" = "Darwin" ]; then export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"; fi
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
CONFIG_FILE="${OPENCLAW_SENTINEL_CONFIG:-$OPENCLAW_HOME/sentinel.json}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/notify.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-memory.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/tg-helper.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/recovery.sh"

RUN_HEALTH=1
RUN_BACKUP=1
FORCE_BACKUP=0
SHOW_STATUS=0
RESET_INCIDENT=0
MIGRATE=0
SENTINEL_DRY_RUN=0

sentinel_usage() {
  cat <<'EOFHELP'
Usage: sentinel.sh [flags]

Flags:
  --backup-only      Run backup cycle only
  --health-only      Run health/recovery only
  --force-backup     Force backup even if schedule says skip
  --dry-run          Log actions without executing mutating commands
  --status           Show current state JSON
  --reset-incident   Clear incident state and failure counter
  --migrate          Migrate legacy watchdog/backup configs into sentinel.json
  --help             Show this help
EOFHELP
}

sentinel_log() {
  local msg="$1"
  local log_dir="${LOG_DIR:-${OPENCLAW_HOME:-$HOME/.openclaw}/logs}"
  mkdir -p "$log_dir"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$log_dir/sentinel.log"
}

sentinel_parse_args() {
  local seen_backup_only=0 seen_health_only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backup-only) RUN_HEALTH=0; RUN_BACKUP=1; seen_backup_only=1 ;;
      --health-only) RUN_HEALTH=1; RUN_BACKUP=0; seen_health_only=1 ;;
      --force-backup) FORCE_BACKUP=1 ;;
      --dry-run) SENTINEL_DRY_RUN=1 ;;
      --status) SHOW_STATUS=1 ;;
      --reset-incident) RESET_INCIDENT=1 ;;
      --migrate) MIGRATE=1 ;;
      --help|-h) sentinel_usage; exit 0 ;;
      *) printf 'sentinel: unknown flag %s\n' "$1" >&2; sentinel_usage >&2; exit 1 ;;
    esac
    shift
  done
  if [ "$seen_backup_only" -eq 1 ] && [ "$seen_health_only" -eq 1 ]; then
    printf 'sentinel: --backup-only and --health-only cannot be used together\n' >&2
    exit 1
  fi
}

sentinel_int_or_default() {
  local value="$1" fallback="$2"
  [[ "$value" =~ ^-?[0-9]+$ ]] && printf '%s\n' "$value" || printf '%s\n' "$fallback"
}

sentinel_bool_or_default() {
  local value="$1" fallback="$2"
  case "$value" in true|false) printf '%s\n' "$value" ;; *) printf '%s\n' "$fallback" ;; esac
}

sentinel_load_runtime_config() {
  local recovery_fields backup_fields notify_fields path_fields
  local rec_max_failures rec_cooldown rec_max_repairs rec_restart rec_doctor rec_rollback
  local rec_codex_timeout rec_rescue_timeout rec_prefix rec_model rec_codex_bin rec_claude_bin
  local backup_enabled backup_schedule backup_system backup_memory backup_repo backup_user
  local backup_skills backup_scripts backup_launchd backup_agents backup_redact backup_max_age
  local notify_token_env notify_chat notify_discord notify_on_recovery notify_on_backup_failure notify_on_backup_success
  local path_state path_lock path_recovery_log path_log_dir

  sentinel_config_load "$CONFIG_FILE"

  recovery_fields="$(jq -r '
    [
      (.health_url // ""),
      (.recovery.max_failures_before_action // ""),
      (.recovery.cooldown_seconds // ""),
      (.recovery.max_repairs_per_incident // ""),
      (.recovery.deterministic_restart_enabled // ""),
      (.recovery.deterministic_doctor_enabled // ""),
      (.recovery.config_rollback_enabled // ""),
      (.recovery.codex_timeout_seconds // ""),
      (.recovery.rescue_timeout_seconds // ""),
      (.recovery.rescue_command_prefix // ""),
      (.recovery.codex_model // ""),
      (.recovery.codex_bin // ""),
      (.recovery.claude_bin // "")
    ] | @tsv
  ' <<<"$SENTINEL_CONFIG_JSON")"
  IFS=$'\t' read -r HEALTH_URL rec_max_failures rec_cooldown rec_max_repairs rec_restart rec_doctor rec_rollback \
    rec_codex_timeout rec_rescue_timeout rec_prefix rec_model rec_codex_bin rec_claude_bin <<<"$recovery_fields"
  HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:18789/healthz}"
  RECOVERY_MAX_FAILURES="$(sentinel_int_or_default "$rec_max_failures" 2)"
  RECOVERY_COOLDOWN_SECONDS="$(sentinel_int_or_default "$rec_cooldown" 1800)"
  RECOVERY_MAX_REPAIRS="$(sentinel_int_or_default "$rec_max_repairs" 3)"
  RECOVERY_RESTART_ENABLED="$(sentinel_bool_or_default "$rec_restart" true)"
  RECOVERY_DOCTOR_ENABLED="$(sentinel_bool_or_default "$rec_doctor" true)"
  RECOVERY_ROLLBACK_ENABLED="$(sentinel_bool_or_default "$rec_rollback" true)"
  RECOVERY_CODEX_TIMEOUT="$(sentinel_int_or_default "$rec_codex_timeout" 180)"
  RECOVERY_RESCUE_TIMEOUT="$(sentinel_int_or_default "$rec_rescue_timeout" 420)"
  RECOVERY_RESCUE_PREFIX="${rec_prefix:-/codex}"
  RECOVERY_CODEX_MODEL="${rec_model:-o4-mini}"
  RECOVERY_CODEX_BIN="$(sentinel_expand_path "${rec_codex_bin:-}")"
  RECOVERY_CLAUDE_BIN="$(sentinel_expand_path "${rec_claude_bin:-}")"

  backup_fields="$(jq -r '
    [
      (.backup.enabled // ""),
      (.backup.schedule // ""),
      (.backup.system_backup_dir // ""),
      (.backup.memory_backup_dir // ""),
      (.backup.github_repo // ""),
      (.backup.github_user // ""),
      (.backup.include_skills // ""),
      (.backup.include_scripts // ""),
      (.backup.include_launchd // ""),
      (.backup.include_agents // ""),
      (.backup.redact_env_values // ""),
      (.backup.max_backup_age_hours // "")
    ] | @tsv
  ' <<<"$SENTINEL_CONFIG_JSON")"
  IFS=$'\t' read -r backup_enabled backup_schedule backup_system backup_memory backup_repo backup_user \
    backup_skills backup_scripts backup_launchd backup_agents backup_redact backup_max_age <<<"$backup_fields"
  BACKUP_ENABLED="$(sentinel_bool_or_default "$backup_enabled" true)"
  BACKUP_SCHEDULE="${backup_schedule:-04:00}"
  BACKUP_SYSTEM_DIR="$(sentinel_expand_path "${backup_system:-~/backups/openclaw-system}")"
  BACKUP_MEMORY_DIR="$(sentinel_expand_path "${backup_memory:-~/backups/openclaw-memory}")"
  BACKUP_GITHUB_REPO="${backup_repo:-}"
  BACKUP_GITHUB_USER="${backup_user:-}"
  BACKUP_INCLUDE_SKILLS="$(sentinel_bool_or_default "$backup_skills" true)"
  BACKUP_INCLUDE_SCRIPTS="$(sentinel_bool_or_default "$backup_scripts" true)"
  BACKUP_INCLUDE_LAUNCHD="$(sentinel_bool_or_default "$backup_launchd" true)"
  BACKUP_INCLUDE_AGENTS="$(sentinel_bool_or_default "$backup_agents" true)"
  BACKUP_REDACT_ENV_VALUES="$(sentinel_bool_or_default "$backup_redact" true)"
  BACKUP_MAX_AGE_HOURS="$(sentinel_int_or_default "$backup_max_age" 30)"
  BACKUP_CRITICAL_FILES_NL="$(jq -r '.backup.critical_files[]?' <<<"$SENTINEL_CONFIG_JSON")"
  [ -n "$BACKUP_CRITICAL_FILES_NL" ] || BACKUP_CRITICAL_FILES_NL=$'openclaw/openclaw.json\nworkspace-config/AGENTS.md\nworkspace-config/SOUL.md'

  notify_fields="$(jq -r '
    [
      (.notifications.telegram_bot_token_env // ""),
      (.notifications.telegram_chat_id // ""),
      (.notifications.discord_webhook_url // ""),
      (.notifications.notify_on_recovery // ""),
      (.notifications.notify_on_backup_failure // ""),
      (.notifications.notify_on_backup_success // "")
    ] | @tsv
  ' <<<"$SENTINEL_CONFIG_JSON")"
  IFS=$'\t' read -r notify_token_env notify_chat notify_discord notify_on_recovery notify_on_backup_failure notify_on_backup_success <<<"$notify_fields"
  NOTIFY_TOKEN_ENV="${notify_token_env:-TELEGRAM_BOT_TOKEN_AVA}"
  NOTIFY_CHAT_ID="${notify_chat:-}"
  NOTIFY_DISCORD="${notify_discord:-}"
  NOTIFY_ON_RECOVERY="$(sentinel_bool_or_default "$notify_on_recovery" true)"
  NOTIFY_ON_BACKUP_FAILURE="$(sentinel_bool_or_default "$notify_on_backup_failure" true)"
  NOTIFY_ON_BACKUP_SUCCESS="$(sentinel_bool_or_default "$notify_on_backup_success" false)"

  path_fields="$(jq -r '
    [
      (.state_file // ""),
      (.lock_file // ""),
      (.recovery_log // ""),
      (.log_dir // "")
    ] | @tsv
  ' <<<"$SENTINEL_CONFIG_JSON")"
  IFS=$'\t' read -r path_state path_lock path_recovery_log path_log_dir <<<"$path_fields"
  STATE_FILE="$(sentinel_expand_path "${path_state:-$OPENCLAW_HOME/state/sentinel-state.json}")"
  LOCK_FILE="$(sentinel_expand_path "${path_lock:-$OPENCLAW_HOME/state/sentinel.lock}")"
  RECOVERY_LOG="$(sentinel_expand_path "${path_recovery_log:-$OPENCLAW_HOME/workspace/memory/recovery-log.md}")"
  LOG_DIR="$(sentinel_expand_path "${path_log_dir:-$OPENCLAW_HOME/logs}")"
  RECOVERY_OFFSET_FILE="$(dirname "$STATE_FILE")/sentinel-rescue-offset"

  sentinel_notify_bootstrap_env "$NOTIFY_TOKEN_ENV"
  sentinel_notify_init "$NOTIFY_TOKEN_ENV" "$NOTIFY_CHAT_ID" "$NOTIFY_DISCORD"
}

main() {
  local previous_failures
  sentinel_parse_args "$@"

  if [ "$MIGRATE" = "1" ]; then
    sentinel_config_require_jq
    sentinel_config_migrate_legacy "$CONFIG_FILE"
  fi

  sentinel_load_runtime_config
  mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$RECOVERY_LOG")"
  sentinel_state_init "$STATE_FILE"

  if [ "$SHOW_STATUS" = "1" ]; then
    sentinel_state_read "$STATE_FILE" | jq '.'
    exit 0
  fi

  if [ "$RESET_INCIDENT" = "1" ]; then
    sentinel_state_reset_incident "$STATE_FILE"
    sentinel_log "sentinel: incident state reset"
    exit 0
  fi

  if ! sentinel_lock_acquire "$LOCK_FILE" 900; then
    sentinel_log "sentinel: another invocation is active; skipping"
    exit 0
  fi
  trap 'sentinel_lock_release "$LOCK_FILE"' EXIT

  if [ "$RUN_HEALTH" = "1" ]; then
    previous_failures="$(sentinel_state_get "$STATE_FILE" '.health.consecutive_failures' '0')"
    if sentinel_health_probe "$HEALTH_URL" 5; then
      if [ "$previous_failures" -gt 0 ] && [ "$NOTIFY_ON_RECOVERY" = "true" ]; then
        sentinel_notify_send "🟢 OpenClaw gateway healthy again after ${previous_failures} failed checks."
      fi
      sentinel_state_mark_health_success "$STATE_FILE"
      [ "$RUN_BACKUP" = "1" ] && sentinel_backup_run_cycle "$FORCE_BACKUP"
    else
      sentinel_state_mark_health_failure "$STATE_FILE"
      sentinel_recovery_run
    fi
  elif [ "$RUN_BACKUP" = "1" ]; then
    sentinel_backup_run_cycle "$FORCE_BACKUP"
  fi
}

main "$@"
