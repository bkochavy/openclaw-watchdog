#!/usr/bin/env bash
# shellcheck shell=bash

SENTINEL_NOTIFY_TG_TOKEN=""
SENTINEL_NOTIFY_TG_CHAT=""
SENTINEL_NOTIFY_DISCORD_WEBHOOK=""

sentinel_notify_log() {
  local msg="$1"
  if declare -F sentinel_log >/dev/null 2>&1; then
    sentinel_log "$msg"
  fi
}

sentinel_notify_load_env_file() {
  local env_file="$1"
  local line key value

  [ -f "$env_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      value="${value%$'\r'}"
      if [[ "$value" =~ ^\".*\"$ ]]; then
        value="${value#\"}"
        value="${value%\"}"
      fi
      export "$key=$value"
    fi
  done < "$env_file"
}

sentinel_notify_bootstrap_env() {
  local openclaw_home="${OPENCLAW_HOME:-$HOME/.openclaw}"
  sentinel_notify_load_env_file "$HOME/.config/env/global.env"
  sentinel_notify_load_env_file "$openclaw_home/.env"
}

sentinel_notify_init() {
  local token_env="$1"
  local chat_id="$2"
  local discord_webhook="$3"

  SENTINEL_NOTIFY_TG_TOKEN="$(printenv "$token_env" 2>/dev/null || true)"
  SENTINEL_NOTIFY_TG_CHAT="$chat_id"
  SENTINEL_NOTIFY_DISCORD_WEBHOOK="$discord_webhook"
}

sentinel_notify_telegram() {
  local msg="$1"

  if [ -z "$SENTINEL_NOTIFY_TG_TOKEN" ] || [ -z "$SENTINEL_NOTIFY_TG_CHAT" ]; then
    return 0
  fi

  curl -fsS --max-time 10 "https://api.telegram.org/bot${SENTINEL_NOTIFY_TG_TOKEN}/sendMessage" \
    -d chat_id="$SENTINEL_NOTIFY_TG_CHAT" \
    -d text="$msg" \
    -d parse_mode="Markdown" >/dev/null 2>&1 || {
      sentinel_notify_log "sentinel: telegram send failed"
      return 1
    }
}

sentinel_notify_discord() {
  local msg="$1"

  if [ -z "$SENTINEL_NOTIFY_DISCORD_WEBHOOK" ]; then
    return 0
  fi

  curl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg content "$msg" '{content: $content}')" \
    "$SENTINEL_NOTIFY_DISCORD_WEBHOOK" >/dev/null 2>&1 || {
      sentinel_notify_log "sentinel: discord send failed"
      return 1
    }
}

sentinel_notify_send() {
  local msg="$1"
  sentinel_notify_telegram "$msg" || true
  sentinel_notify_discord "$msg" || true
}
