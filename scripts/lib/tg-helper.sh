#!/usr/bin/env bash
# shellcheck shell=bash

sentinel_tg_require() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ]
}

sentinel_tg_send() {
  local token="$1" chat_id="$2" suffix="$3" message="$4"
  sentinel_tg_require "$token" "$chat_id" || return 1
  if [ -n "$suffix" ] && [[ "$message" != *"$suffix" ]]; then
    message="${message}
${suffix}"
  fi
  curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/sendMessage" \
    -d chat_id="$chat_id" -d text="$message" -d parse_mode="Markdown" >/dev/null 2>&1
}

sentinel_tg_latest_update_id() {
  local token="$1"
  sentinel_tg_require "$token" "x" || { printf '0\n'; return 0; }
  curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getUpdates" -d limit=1 -d offset=-1 \
    | jq -r '.result[-1].update_id // 0' 2>/dev/null || printf '0\n'
}

sentinel_tg_read_offset() {
  local file="$1"
  [ -f "$file" ] && cat "$file" || printf '0\n'
}

sentinel_tg_write_offset() {
  local file="$1" value="$2"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$value" > "$file"
}

sentinel_tg_prime_offset() {
  local token="$1" offset_file="$2" last_id
  last_id="$(sentinel_tg_latest_update_id "$token")"
  sentinel_tg_write_offset "$offset_file" "$((last_id + 1))"
}

sentinel_tg_fetch_prefixed_command() {
  local token="$1" chat_id="$2" prefix="$3" offset_file="$4"
  local offset updates last_id command
  sentinel_tg_require "$token" "$chat_id" || return 1
  offset="$(sentinel_tg_read_offset "$offset_file")"
  updates="$(curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getUpdates" -d offset="$offset" -d timeout=0 2>/dev/null || true)"
  last_id="$(printf '%s\n' "$updates" | jq -r '.result[-1].update_id // empty' 2>/dev/null || true)"
  [ -n "$last_id" ] && sentinel_tg_write_offset "$offset_file" "$((last_id + 1))"

  command="$(printf '%s\n' "$updates" | jq -r --arg chat "$chat_id" --arg p "$prefix" '
    [.result[]
      | select((.message.chat.id | tostring) == $chat)
      | (.message.text // empty)]
    | reverse | map(select(startswith($p))) | .[0] // empty
  ' 2>/dev/null || true)"

  [ -z "$command" ] && return 1
  command="${command#"$prefix"}"
  command="${command# }"
  [ -n "$command" ] || return 2
  printf '%s\n' "$command"
}

sentinel_tg_ask() {
  local token="$1" chat_id="$2" suffix="$3" health_url="$4" question="$5"
  local offset payload reply i reply_id
  sentinel_tg_require "$token" "$chat_id" || return 1
  offset="$(( $(sentinel_tg_latest_update_id "$token") + 1 ))"
  sentinel_tg_send "$token" "$chat_id" "$suffix" "$question" || return 1

  i=1
  while [ "$i" -le 24 ]; do
    sleep 5
    if [ -n "$health_url" ] && curl -fsS --max-time 2 "$health_url" >/dev/null 2>&1; then
      sentinel_tg_send "$token" "$chat_id" "$suffix" "Gateway recovered while waiting for reply."
      return 1
    fi

    payload="$(curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getUpdates" -d offset="$offset" -d timeout=0 2>/dev/null || true)"
    reply="$(printf '%s\n' "$payload" | jq -r --arg chat "$chat_id" '
      .result[] | select((.message.chat.id | tostring) == $chat) | (.message.text // empty)
    ' 2>/dev/null | head -1)"

    if [ -n "$reply" ]; then
      reply_id="$(printf '%s\n' "$payload" | jq -r '.result[-1].update_id // empty' 2>/dev/null || true)"
      [ -n "$reply_id" ] && curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getUpdates" -d offset="$((reply_id + 1))" -d timeout=0 >/dev/null 2>&1 || true
      printf '%s\n' "$reply"
      return 0
    fi
    i=$((i + 1))
  done

  sentinel_tg_send "$token" "$chat_id" "$suffix" "No response after 2 minutes."
  return 1
}

sentinel_tg_write_runtime_helper() {
  local helper_path="$1"
  cat > "$helper_path" <<'EOFRUNTIME'
#!/usr/bin/env bash
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"
TG_SUFFIX="${TG_SUFFIX:--codexrecov}"
TG_HEALTH_URL="${TG_HEALTH_URL:-http://127.0.0.1:18789/healthz}"

tg_send() {
  local msg="$1"
  [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ] && return 1
  if [ -n "$TG_SUFFIX" ] && [[ "$msg" != *"$TG_SUFFIX" ]]; then msg="${msg}
${TG_SUFFIX}"; fi
  curl -fsS --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT" -d text="$msg" -d parse_mode="Markdown" >/dev/null 2>&1
}

tg_ask() {
  local question="$1" last_id offset payload reply i
  [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ] && return 1
  last_id=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" -d limit=1 -d offset=-1 | jq -r '.result[-1].update_id // 0' 2>/dev/null)
  offset=$((last_id + 1))
  tg_send "$question" || return 1
  for i in $(seq 1 24); do
    sleep 5
    if curl -fsS --max-time 2 "$TG_HEALTH_URL" >/dev/null 2>&1; then return 1; fi
    payload=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" -d offset="$offset" -d timeout=0 2>/dev/null || true)
    reply=$(printf '%s\n' "$payload" | jq -r --arg chat "$TG_CHAT" '.result[] | select((.message.chat.id | tostring) == $chat) | (.message.text // empty)' 2>/dev/null | head -1)
    [ -n "$reply" ] && printf '%s\n' "$reply" && return 0
  done
  return 1
}
EOFRUNTIME
  chmod +x "$helper_path"
}

tg_send() { sentinel_tg_send "${TG_TOKEN:-}" "${TG_CHAT:-}" "${TG_SUFFIX:--codexrecov}" "$1"; }
tg_ask() { sentinel_tg_ask "${TG_TOKEN:-}" "${TG_CHAT:-}" "${TG_SUFFIX:--codexrecov}" "${TG_HEALTH_URL:-http://127.0.0.1:18789/healthz}" "$1"; }

main() {
  case "${1:-}" in
    send) shift; tg_send "$*" ;;
    ask) shift; tg_ask "$*" ;;
    --help|-h|help|"")
      cat <<'EOFHELP'
Usage:
  tg-helper.sh send "message"
  tg-helper.sh ask "question"

Environment:
  TG_TOKEN TG_CHAT TG_SUFFIX TG_HEALTH_URL
EOFHELP
      ;;
    *) printf 'tg-helper: unknown command %s\n' "$1" >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
