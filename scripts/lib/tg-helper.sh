#!/usr/bin/env bash
# Standalone Telegram helper for OpenClaw scripts.

set -uo pipefail

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"
TG_SUFFIX="${TG_SUFFIX:--codexrecov}"
TG_HEALTH_URL="${TG_HEALTH_URL:-http://127.0.0.1:18789}"

_tg_require_env() {
  if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
    echo "tg-helper: set TG_TOKEN and TG_CHAT in the environment" >&2
    return 1
  fi
  return 0
}

# Send a one-way status update.
tg_send() {
  local msg="${1:-}"
  if [ -z "$msg" ]; then
    echo "tg-helper: message is required" >&2
    return 1
  fi

  _tg_require_env || return 1

  if [ -n "$TG_SUFFIX" ] && [[ "$msg" != *"$TG_SUFFIX" ]]; then
    msg="${msg}
${TG_SUFFIX}"
  fi

  curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT" -d text="$msg" -d parse_mode="Markdown" >/dev/null 2>&1
}

# Ask a question and wait up to 2 minutes for a same-chat response.
tg_ask() {
  local question="${1:-}"
  if [ -z "$question" ]; then
    echo "tg-helper: question is required" >&2
    return 1
  fi

  _tg_require_env || return 1

  local last_update offset
  last_update=$(curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" \
    -d limit=1 -d offset=-1 | jq -r '.result[-1].update_id // 0' 2>/dev/null)
  offset=$((last_update + 1))

  if [ -n "$TG_SUFFIX" ] && [[ "$question" != *"$TG_SUFFIX" ]]; then
    question="${question}
${TG_SUFFIX}"
  fi

  curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT" -d text="$question" -d parse_mode="Markdown" >/dev/null 2>&1

  local i payload reply
  for i in $(seq 1 24); do
    sleep 5

    if curl -s --max-time 2 "$TG_HEALTH_URL" >/dev/null 2>&1; then
      tg_send "🟢 Gateway came back on its own! Stopping repair."
      echo ""
      return 1
    fi

    payload=$(curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" \
      -d offset="$offset" -d timeout=0)

    reply=$(printf "%s" "$payload" | jq -r --arg chat "$TG_CHAT" '
      .result[]
      | select((.message.chat.id | tostring) == $chat)
      | (.message.text // empty)
    ' 2>/dev/null | head -1)

    if [ -n "$reply" ]; then
      local reply_id
      reply_id=$(printf "%s" "$payload" | jq -r '.result[-1].update_id // empty' 2>/dev/null)
      if [ -n "$reply_id" ]; then
        curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" \
          -d offset="$((reply_id + 1))" -d timeout=0 >/dev/null 2>&1
      fi
      echo "$reply"
      return 0
    fi
  done

  tg_send "⏳ No response after 2 min. Proceeding with safe defaults (no destructive changes)."
  echo ""
  return 1
}

show_help() {
  cat <<'HELPEOF'
Usage:
  tg-helper.sh send "message"
  tg-helper.sh ask "question?"
  tg-helper.sh --help

Environment:
  TG_TOKEN       Telegram bot token (required)
  TG_CHAT        Telegram chat ID (required)
  TG_SUFFIX      Suffix appended to outgoing messages (default: -codexrecov)
  TG_HEALTH_URL  Health URL checked during tg_ask polling (default: http://127.0.0.1:18789)

The script can be sourced:
  source ~/.openclaw/bin/tg-helper.sh
  tg_send "hello"
HELPEOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    send)
      shift
      tg_send "$*"
      ;;
    ask)
      shift
      tg_ask "$*"
      ;;
    --help|-h|help|"")
      show_help
      ;;
    *)
      echo "tg-helper: unknown command '$cmd'" >&2
      show_help >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
