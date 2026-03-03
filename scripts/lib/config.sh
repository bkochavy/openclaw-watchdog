#!/usr/bin/env bash
# shellcheck shell=bash

sentinel_expand_path() {
  local raw="${1:-}"
  case "$raw" in
    "~") printf '%s\n' "$HOME" ;;
    ~/*) printf '%s\n' "$HOME/${raw#~/}" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

sentinel_config_default_json() {
  local openclaw_home="${OPENCLAW_HOME:-$HOME/.openclaw}"
  jq -n --arg home "$openclaw_home" '
    {
      health_url: "http://127.0.0.1:18789/healthz",
      check_interval_seconds: 300,
      recovery: {
        max_failures_before_action: 2,
        cooldown_seconds: 1800,
        max_repairs_per_incident: 3,
        deterministic_restart_enabled: true,
        deterministic_doctor_enabled: true,
        config_rollback_enabled: true,
        codex_timeout_seconds: 180,
        rescue_timeout_seconds: 420,
        rescue_command_prefix: "/codex",
        codex_model: "gpt-5.3-codex",
        codex_bin: "",
        claude_bin: ""
      },
      backup: {
        enabled: true,
        schedule: "04:00",
        system_backup_dir: "~/backups/openclaw-system",
        memory_backup_dir: "~/backups/openclaw-memory",
        github_repo: "",
        github_user: "",
        include_skills: true,
        include_scripts: true,
        include_launchd: true,
        include_agents: true,
        redact_env_values: true,
        max_backup_age_hours: 30,
        critical_files: ["openclaw/openclaw.json", "workspace-config/AGENTS.md", "workspace-config/SOUL.md"]
      },
      notifications: {
        telegram_bot_token_env: "TELEGRAM_BOT_TOKEN_AVA",
        telegram_chat_id: "",
        discord_webhook_url: "",
        notify_on_recovery: true,
        notify_on_backup_failure: true,
        notify_on_backup_success: false
      },
      state_file: ($home + "/state/sentinel-state.json"),
      lock_file: ($home + "/state/sentinel.lock"),
      recovery_log: ($home + "/workspace/memory/recovery-log.md"),
      log_dir: ($home + "/logs")
    }
  '
}

sentinel_config_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'sentinel: jq is required\n' >&2
    return 1
  fi
}

sentinel_config_read_file() {
  local file="$1"
  [ -f "$file" ] && jq -c '.' "$file" 2>/dev/null || printf '{}\n'
}

sentinel_config_build_from_legacy() {
  local watchdog_file="$1" backup_file="$2" defaults watchdog_json backup_json
  defaults="$(sentinel_config_default_json)"
  watchdog_json="$(sentinel_config_read_file "$watchdog_file")"
  backup_json="$(sentinel_config_read_file "$backup_file")"
  jq -n --argjson base "$defaults" --argjson wd "$watchdog_json" --argjson bk "$backup_json" '
    $base
    | .health_url = ($wd.health_url // .health_url)
    | .notifications.telegram_bot_token_env = ($wd.telegram_bot_token_env // $bk.telegram_bot_token_env // .notifications.telegram_bot_token_env)
    | .notifications.telegram_chat_id = ($wd.telegram_chat_id // $bk.telegram_chat_id // .notifications.telegram_chat_id)
    | .recovery.max_failures_before_action = ($wd.max_failures // .recovery.max_failures_before_action)
    | .recovery.cooldown_seconds = ($wd.cooldown_seconds // .recovery.cooldown_seconds)
    | .recovery.max_repairs_per_incident = ($wd.max_repairs_per_incident // .recovery.max_repairs_per_incident)
    | .recovery.codex_timeout_seconds = ($wd.codex_timeout_seconds // .recovery.codex_timeout_seconds)
    | .recovery.rescue_timeout_seconds = ($wd.rescue_command_timeout_seconds // .recovery.rescue_timeout_seconds)
    | .recovery.rescue_command_prefix = ($wd.rescue_command_prefix // .recovery.rescue_command_prefix)
    | .recovery.codex_model = ($wd.codex_model // .recovery.codex_model)
    | .recovery.codex_bin = ($wd.codex_bin // .recovery.codex_bin)
    | .recovery.claude_bin = ($wd.claude_bin // .recovery.claude_bin)
    | .state_file = ($wd.state_file // .state_file)
    | .lock_file = ($wd.lock_file // .lock_file)
    | .recovery_log = ($wd.recovery_log // .recovery_log)
    | .backup.system_backup_dir = ($bk.backup_dir // $bk.system_backup_dir // .backup.system_backup_dir)
    | .backup.memory_backup_dir = ($bk.memory_backup_dir // .backup.memory_backup_dir)
    | .backup.github_repo = ($bk.github_repo // .backup.github_repo)
    | .backup.github_user = ($bk.github_user // .backup.github_user)
    | .backup.include_skills = ($bk.include_skills // .backup.include_skills)
    | .backup.include_scripts = ($bk.include_scripts // .backup.include_scripts)
    | .backup.include_launchd = ($bk.include_launchd // .backup.include_launchd)
    | .backup.include_agents = ($bk.include_agents // .backup.include_agents)
    | .backup.redact_env_values = ($bk.redact_env_values // .backup.redact_env_values)
    | .backup.max_backup_age_hours = ($bk.max_backup_age_hours // .backup.max_backup_age_hours)
    | .backup.critical_files = ($bk.critical_files // .backup.critical_files)
  '
}

sentinel_config_write() {
  local target_file="$1" json="$2" target_dir tmp_file
  target_dir="$(dirname "$target_file")"
  mkdir -p "$target_dir"
  tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
  printf '%s\n' "$json" > "$tmp_file"
  mv "$tmp_file" "$target_file"
}

sentinel_config_load() {
  local config_file="${1:-${OPENCLAW_SENTINEL_CONFIG:-${OPENCLAW_HOME:-$HOME/.openclaw}/sentinel.json}}"
  local watchdog_file="${OPENCLAW_WATCHDOG_CONFIG:-${OPENCLAW_HOME:-$HOME/.openclaw}/watchdog.json}"
  local backup_file="${OPENCLAW_BACKUP_CONFIG:-${OPENCLAW_HOME:-$HOME/.openclaw}/backup.json}"
  local defaults source_json final_json
  sentinel_config_require_jq || return 1
  defaults="$(sentinel_config_default_json)"
  if [ -f "$config_file" ]; then
    source_json="$(jq -c '.' "$config_file" 2>/dev/null || printf '{}\n')"
    SENTINEL_CONFIG_SOURCE="sentinel"
  elif [ -f "$watchdog_file" ] || [ -f "$backup_file" ]; then
    source_json="$(sentinel_config_build_from_legacy "$watchdog_file" "$backup_file")"
    SENTINEL_CONFIG_SOURCE="legacy"
  else
    source_json='{}'
    SENTINEL_CONFIG_SOURCE="default"
  fi
  final_json="$(jq -n --argjson a "$defaults" --argjson b "$source_json" '$a * $b')"
  SENTINEL_CONFIG_FILE="$config_file"
  SENTINEL_CONFIG_JSON="$final_json"
}

sentinel_config_migrate_legacy() {
  local config_file="${1:-${OPENCLAW_SENTINEL_CONFIG:-${OPENCLAW_HOME:-$HOME/.openclaw}/sentinel.json}}"
  local watchdog_file="${OPENCLAW_WATCHDOG_CONFIG:-${OPENCLAW_HOME:-$HOME/.openclaw}/watchdog.json}"
  local backup_file="${OPENCLAW_BACKUP_CONFIG:-${OPENCLAW_HOME:-$HOME/.openclaw}/backup.json}"
  local merged
  merged="$(sentinel_config_build_from_legacy "$watchdog_file" "$backup_file")"
  sentinel_config_write "$config_file" "$(jq '.' <<<"$merged")"
}

sentinel_config_get_string() {
  local filter="$1" fallback="$2" value
  value="$(jq -r "$filter // empty" <<<"$SENTINEL_CONFIG_JSON" 2>/dev/null || true)"
  [ -n "$value" ] && [ "$value" != "null" ] && printf '%s\n' "$value" || printf '%s\n' "$fallback"
}

sentinel_config_get_int() {
  local filter="$1" fallback="$2" value
  value="$(sentinel_config_get_string "$filter" "$fallback")"
  [[ "$value" =~ ^-?[0-9]+$ ]] && printf '%s\n' "$value" || printf '%s\n' "$fallback"
}

sentinel_config_get_bool() {
  local filter="$1" fallback="$2" value
  value="$(jq -r "$filter // empty" <<<"$SENTINEL_CONFIG_JSON" 2>/dev/null || true)"
  case "$value" in true|false) printf '%s\n' "$value" ;; *) printf '%s\n' "$fallback" ;; esac
}

sentinel_config_get_path() {
  local filter="$1" fallback="$2"
  sentinel_expand_path "$(sentinel_config_get_string "$filter" "$fallback")"
}
