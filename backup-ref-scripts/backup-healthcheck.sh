#!/usr/bin/env bash
set -euo pipefail

# Daily backup health-check.
# Silent on success; sends Telegram alert only when backup is stale or failed.

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CONFIG_PATH="${OPENCLAW_BACKUP_CONFIG:-$HOME/.openclaw/backup.json}"
STATE_FILE="${OPENCLAW_BACKUP_HEALTH_STATE:-/tmp/openclaw-backup-health-state}"
LOG_FILE="${OPENCLAW_BACKUP_LOG:-/tmp/openclaw-backup.log}"
MAX_AGE_HOURS="${OPENCLAW_BACKUP_MAX_AGE_HOURS:-30}"

# Defaults
BACKUP_DIR="$HOME/backups/openclaw-system"
TOKEN_ENV="TELEGRAM_BOT_TOKEN_AVA"
CHAT_ID=""

if [[ -f "$CONFIG_PATH" ]] && command -v jq >/dev/null 2>&1; then
  BACKUP_DIR="$(jq -r '.backup_dir // empty' "$CONFIG_PATH" 2>/dev/null || true)"
  [[ -z "$BACKUP_DIR" ]] && BACKUP_DIR="$HOME/backups/openclaw-system"

  TOKEN_ENV_CFG="$(jq -r '.telegram_bot_token_env // empty' "$CONFIG_PATH" 2>/dev/null || true)"
  [[ -n "$TOKEN_ENV_CFG" ]] && TOKEN_ENV="$TOKEN_ENV_CFG"

  CHAT_ID_CFG="$(jq -r '.telegram_chat_id // empty' "$CONFIG_PATH" 2>/dev/null || true)"
  [[ -n "$CHAT_ID_CFG" ]] && CHAT_ID="$CHAT_ID_CFG"
fi

# Expand ~ in backup_dir
BACKUP_DIR="${BACKUP_DIR/#\~/$HOME}"
MANIFEST="$BACKUP_DIR/backup-manifest.txt"

TG_TOKEN="${!TOKEN_ENV:-}"

notify_telegram() {
  local msg="$1"
  [[ -z "$TG_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$msg" \
    -d parse_mode="Markdown" >/dev/null 2>&1 || true
}

reasons=()

if [[ ! -f "$MANIFEST" ]]; then
  reasons+=("backup-manifest missing: $MANIFEST")
else
  now_epoch=$(date +%s)
  mtime_epoch=$(stat -f %m "$MANIFEST" 2>/dev/null || echo 0)
  age_hours=$(( (now_epoch - mtime_epoch) / 3600 ))
  if (( age_hours > MAX_AGE_HOURS )); then
    reasons+=("manifest stale: ${age_hours}h old (threshold ${MAX_AGE_HOURS}h)")
  fi
fi

if [[ -f "$LOG_FILE" ]]; then
  # Only consider recent failures (last 400 lines)
  recent_fail=$(tail -400 "$LOG_FILE" | grep -E "push FAILED after retry|critical files missing" | tail -1 || true)
  if [[ -n "$recent_fail" ]]; then
    reasons+=("latest log failure: ${recent_fail}")
  fi
fi

if (( ${#reasons[@]} == 0 )); then
  # Success: record healthy check, no message
  printf 'ok|%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$STATE_FILE"
  exit 0
fi

# Build dedupe key (same reasons won't re-alert continuously)
key="$(printf '%s|' "${reasons[@]}" | shasum | awk '{print $1}')"
prev_key=""
if [[ -f "$STATE_FILE" ]]; then
  prev_key="$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null || true)"
fi

if [[ "$key" == "$prev_key" ]]; then
  # Already alerted for this exact state
  exit 0
fi

last_commit=""
if [[ -d "$BACKUP_DIR/.git" ]]; then
  last_commit="$(git -C "$BACKUP_DIR" log -1 --pretty=format:'%h %ad %s' --date=local 2>/dev/null || true)"
fi

msg="⚠️ *OpenClaw backup health check failed*\n\n"
msg+="Host: $(hostname)\n"
msg+="Time: $(date '+%Y-%m-%d %H:%M:%S %Z')\n"
msg+="Manifest: ${MANIFEST}\n"
[[ -n "$last_commit" ]] && msg+="Last commit: ${last_commit}\n"
msg+="\nReasons:\n"
for r in "${reasons[@]}"; do
  msg+="- ${r}\n"
done
msg+="\nCheck: ${LOG_FILE}"

notify_telegram "$msg"
printf '%s|%s\n' "$key" "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$STATE_FILE"

exit 0
