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
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_DIR/sentinel.log"
}

sentinel_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backup-only) RUN_HEALTH=0; RUN_BACKUP=1 ;;
      --health-only) RUN_HEALTH=1; RUN_BACKUP=0 ;;
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
}

sentinel_load_runtime_config() {
  sentinel_config_load "$CONFIG_FILE"
  HEALTH_URL="$(sentinel_config_get_string '.health_url' 'http://127.0.0.1:18789/healthz')"

  RECOVERY_MAX_FAILURES="$(sentinel_config_get_int '.recovery.max_failures_before_action' 2)"
  RECOVERY_COOLDOWN_SECONDS="$(sentinel_config_get_int '.recovery.cooldown_seconds' 1800)"
  RECOVERY_MAX_REPAIRS="$(sentinel_config_get_int '.recovery.max_repairs_per_incident' 3)"
  RECOVERY_RESTART_ENABLED="$(sentinel_config_get_bool '.recovery.deterministic_restart_enabled' true)"
  RECOVERY_DOCTOR_ENABLED="$(sentinel_config_get_bool '.recovery.deterministic_doctor_enabled' true)"
  RECOVERY_ROLLBACK_ENABLED="$(sentinel_config_get_bool '.recovery.config_rollback_enabled' true)"
  RECOVERY_CODEX_TIMEOUT="$(sentinel_config_get_int '.recovery.codex_timeout_seconds' 180)"
  RECOVERY_RESCUE_TIMEOUT="$(sentinel_config_get_int '.recovery.rescue_timeout_seconds' 420)"
  RECOVERY_RESCUE_PREFIX="$(sentinel_config_get_string '.recovery.rescue_command_prefix' '/codex')"
  RECOVERY_CODEX_MODEL="$(sentinel_config_get_string '.recovery.codex_model' 'gpt-5.3-codex')"
  RECOVERY_CODEX_BIN="$(sentinel_config_get_path '.recovery.codex_bin' '')"
  RECOVERY_CLAUDE_BIN="$(sentinel_config_get_path '.recovery.claude_bin' '')"

  BACKUP_ENABLED="$(sentinel_config_get_bool '.backup.enabled' true)"
  BACKUP_SCHEDULE="$(sentinel_config_get_string '.backup.schedule' '04:00')"
  BACKUP_SYSTEM_DIR="$(sentinel_config_get_path '.backup.system_backup_dir' '~/backups/openclaw-system')"
  BACKUP_MEMORY_DIR="$(sentinel_config_get_path '.backup.memory_backup_dir' '~/backups/openclaw-memory')"
  BACKUP_GITHUB_REPO="$(sentinel_config_get_string '.backup.github_repo' '')"
  BACKUP_GITHUB_USER="$(sentinel_config_get_string '.backup.github_user' '')"
  BACKUP_INCLUDE_SKILLS="$(sentinel_config_get_bool '.backup.include_skills' true)"
  BACKUP_INCLUDE_SCRIPTS="$(sentinel_config_get_bool '.backup.include_scripts' true)"
  BACKUP_INCLUDE_LAUNCHD="$(sentinel_config_get_bool '.backup.include_launchd' true)"
  BACKUP_INCLUDE_AGENTS="$(sentinel_config_get_bool '.backup.include_agents' true)"
  BACKUP_REDACT_ENV_VALUES="$(sentinel_config_get_bool '.backup.redact_env_values' true)"
  BACKUP_MAX_AGE_HOURS="$(sentinel_config_get_int '.backup.max_backup_age_hours' 30)"
  BACKUP_CRITICAL_FILES_NL="$(jq -r '.backup.critical_files[]?' <<<"$SENTINEL_CONFIG_JSON")"
  [ -n "$BACKUP_CRITICAL_FILES_NL" ] || BACKUP_CRITICAL_FILES_NL=$'openclaw/openclaw.json\nworkspace-config/AGENTS.md\nworkspace-config/SOUL.md'

  NOTIFY_TOKEN_ENV="$(sentinel_config_get_string '.notifications.telegram_bot_token_env' 'TELEGRAM_BOT_TOKEN_AVA')"
  NOTIFY_CHAT_ID="$(sentinel_config_get_string '.notifications.telegram_chat_id' '')"
  NOTIFY_DISCORD="$(sentinel_config_get_string '.notifications.discord_webhook_url' '')"
  NOTIFY_ON_RECOVERY="$(sentinel_config_get_bool '.notifications.notify_on_recovery' true)"
  NOTIFY_ON_BACKUP_FAILURE="$(sentinel_config_get_bool '.notifications.notify_on_backup_failure' true)"
  NOTIFY_ON_BACKUP_SUCCESS="$(sentinel_config_get_bool '.notifications.notify_on_backup_success' false)"

  STATE_FILE="$(sentinel_config_get_path '.state_file' "$OPENCLAW_HOME/state/sentinel-state.json")"
  LOCK_FILE="$(sentinel_config_get_path '.lock_file' "$OPENCLAW_HOME/state/sentinel.lock")"
  RECOVERY_LOG="$(sentinel_config_get_path '.recovery_log' "$OPENCLAW_HOME/workspace/memory/recovery-log.md")"
  LOG_DIR="$(sentinel_config_get_path '.log_dir' "$OPENCLAW_HOME/logs")"
  RECOVERY_OFFSET_FILE="$(dirname "$STATE_FILE")/sentinel-rescue-offset"

  sentinel_notify_bootstrap_env
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
