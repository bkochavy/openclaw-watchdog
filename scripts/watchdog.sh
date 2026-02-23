#!/usr/bin/env bash
# OpenClaw Gateway Emergency Recovery Watchdog
# Generalized package version of a production watchdog.

set -uo pipefail

if [[ "$(uname -s)" == "Darwin" ]]; then
  export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
fi
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
CONFIG_FILE_DEFAULT="$OPENCLAW_HOME/watchdog.json"
CONFIG_FILE="${OPENCLAW_WATCHDOG_CONFIG:-$CONFIG_FILE_DEFAULT}"

# Defaults (can be overridden by config)
HEALTH_URL="http://127.0.0.1:18789"
TELEGRAM_BOT_TOKEN_ENV="TELEGRAM_BOT_TOKEN_AVA"
CHAT_ID=""
MAX_FAILURES=2
COOLDOWN_SECONDS=1800
MAX_REPAIRS_PER_INCIDENT=3
CODEX_TIMEOUT=180
RESCUE_CODEX_TIMEOUT=420
RESCUE_COMMAND_PREFIX="/codex"
RECOVERY_LOG="$OPENCLAW_HOME/workspace/memory/recovery-log.md"
STATE_FILE="/tmp/openclaw-watchdog-state"
LOCK_FILE="/tmp/openclaw-watchdog.lock"
CODEX_MODEL="gpt-5.3-codex"
CODEX_BIN=""
CLAUDE_BIN=""
RESCUE_OFFSET_FILE="/tmp/openclaw-watchdog-rescue-offset"
TIMEOUT_WARN_FILE="/tmp/openclaw-watchdog-timeout.warned"

CODEX_RECOV_SUFFIX="-codexrecov"

LOG_DIR="$OPENCLAW_HOME/logs"
LOG_FILE="$LOG_DIR/watchdog.log"
TMP_BASE="${TMPDIR:-/tmp}"
TG_HELPER="$TMP_BASE/openclaw-tg-helper.sh"

BOT_TOKEN=""
TIMEOUT_BIN=""

expand_path() {
  local path="$1"
  case "$path" in
    "~")
      echo "$HOME"
      ;;
    ~/*)
      echo "$HOME/${path#~/}"
      ;;
    *)
      echo "$path"
      ;;
  esac
}

config_has_key() {
  local key="$1"
  jq -e --arg key "$key" 'has($key) and .[$key] != null' "$CONFIG_FILE" >/dev/null 2>&1
}

config_get_string() {
  local key="$1"
  local fallback="$2"

  if [ ! -f "$CONFIG_FILE" ] || ! command -v jq >/dev/null 2>&1; then
    echo "$fallback"
    return
  fi

  if config_has_key "$key"; then
    local value
    value=$(jq -r --arg key "$key" '.[$key]' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$value" ]; then
      echo "$value"
      return
    fi
  fi

  echo "$fallback"
}

config_get_int() {
  local key="$1"
  local fallback="$2"
  local value

  value=$(config_get_string "$key" "$fallback")
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    echo "$value"
  else
    echo "$fallback"
  fi
}

load_dotenv() {
  local env_file="$OPENCLAW_HOME/.env"
  if [ ! -f "$env_file" ]; then
    return
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        continue
        ;;
    esac
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "$line"
    fi
  done < "$env_file"
}

load_config() {
  if [ -f "$CONFIG_FILE" ] && ! command -v jq >/dev/null 2>&1; then
    echo "watchdog: jq is required to read config: $CONFIG_FILE" >&2
    exit 1
  fi

  HEALTH_URL=$(config_get_string "health_url" "$HEALTH_URL")
  TELEGRAM_BOT_TOKEN_ENV=$(config_get_string "telegram_bot_token_env" "$TELEGRAM_BOT_TOKEN_ENV")
  CHAT_ID=$(config_get_string "telegram_chat_id" "$CHAT_ID")

  MAX_FAILURES=$(config_get_int "max_failures" "$MAX_FAILURES")
  COOLDOWN_SECONDS=$(config_get_int "cooldown_seconds" "$COOLDOWN_SECONDS")
  MAX_REPAIRS_PER_INCIDENT=$(config_get_int "max_repairs_per_incident" "$MAX_REPAIRS_PER_INCIDENT")
  CODEX_TIMEOUT=$(config_get_int "codex_timeout_seconds" "$CODEX_TIMEOUT")
  RESCUE_CODEX_TIMEOUT=$(config_get_int "rescue_command_timeout_seconds" "$RESCUE_CODEX_TIMEOUT")

  RESCUE_COMMAND_PREFIX=$(config_get_string "rescue_command_prefix" "$RESCUE_COMMAND_PREFIX")
  RECOVERY_LOG=$(expand_path "$(config_get_string "recovery_log" "$RECOVERY_LOG")")

  STATE_FILE=$(expand_path "$(config_get_string "state_file" "$STATE_FILE")")
  LOCK_FILE=$(expand_path "$(config_get_string "lock_file" "$LOCK_FILE")")
  CODEX_MODEL=$(config_get_string "codex_model" "$CODEX_MODEL")
  CODEX_BIN=$(expand_path "$(config_get_string "codex_bin" "$CODEX_BIN")")
  CLAUDE_BIN=$(expand_path "$(config_get_string "claude_bin" "$CLAUDE_BIN")")

  # Optional advanced keys for state/cooldown artifacts.
  RESCUE_OFFSET_FILE=$(expand_path "$(config_get_string "rescue_offset_file" "$RESCUE_OFFSET_FILE")")
  TIMEOUT_WARN_FILE=$(expand_path "$(config_get_string "timeout_warn_file" "$TIMEOUT_WARN_FILE")")

  LOG_DIR="$OPENCLAW_HOME/logs"
  LOG_FILE="$LOG_DIR/watchdog.log"
  TG_HELPER="${TMPDIR:-/tmp}/openclaw-tg-helper.sh"
}

resolve_coding_agent() {
  # 1. Try configured codex_bin
  if [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ]; then
    echo "codex:$CODEX_BIN"
    return 0
  fi

  # 2. Try codex on PATH
  if command -v codex >/dev/null 2>&1; then
    echo "codex:$(command -v codex)"
    return 0
  fi

  # 3. Try common codex paths
  for p in /opt/homebrew/bin/codex /usr/local/bin/codex; do
    if [ -x "$p" ]; then
      echo "codex:$p"
      return 0
    fi
  done

  # 4. Try configured claude_bin first, then PATH/common paths
  if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
    echo "claude:$CLAUDE_BIN"
    return 0
  fi
  if command -v claude >/dev/null 2>&1; then
    echo "claude:$(command -v claude)"
    return 0
  fi
  for p in /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [ -x "$p" ]; then
      echo "claude:$p"
      return 0
    fi
  done

  # 5. Nothing found
  echo "none:"
  return 1
}

resolve_openclaw_bin() {
  if command -v openclaw >/dev/null 2>&1; then
    command -v openclaw
    return 0
  fi

  if [ -x /opt/homebrew/bin/openclaw ]; then
    echo "/opt/homebrew/bin/openclaw"
    return 0
  fi

  if [ -x /usr/local/bin/openclaw ]; then
    echo "/usr/local/bin/openclaw"
    return 0
  fi

  echo "openclaw"
  return 0
}

resolve_node_bin() {
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi

  if [ -x /opt/homebrew/bin/node ]; then
    echo "/opt/homebrew/bin/node"
    return 0
  fi

  if [ -x /usr/local/bin/node ]; then
    echo "/usr/local/bin/node"
    return 0
  fi

  echo "node"
  return 0
}

log() {
  mkdir -p "$LOG_DIR"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

notify_telegram() {
  local msg="$1"
  if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d chat_id="$CHAT_ID" -d text="$msg" -d parse_mode="Markdown" >/dev/null 2>&1 || true
  fi
}

notify_telegram_codex() {
  local msg="$1"
  notify_telegram "${msg}
${CODEX_RECOV_SUFFIX}"
}

notify_no_agent_found() {
  notify_telegram "🚨 No coding agent found (Codex or Claude Code).
Install one to enable auto-repair:
  npm install -g @openai/codex    # Codex
  npm install -g @anthropic-ai/claude-code  # Claude Code

Then restart the watchdog: bash ~/.openclaw/bin/watchdog.sh"
}

run_coding_agent_prompt() {
  local agent_type="$1"
  local agent_bin="$2"
  local timeout_seconds="$3"
  local prompt="$4"

  case "$agent_type" in
    codex)
      run_with_timeout "$timeout_seconds" "$agent_bin" \
        --dangerously-bypass-approvals-and-sandbox \
        --model "$CODEX_MODEL" \
        "$prompt"
      return $?
      ;;
    claude)
      run_with_timeout "$timeout_seconds" "$agent_bin" \
        --dangerously-skip-permissions \
        "$prompt"
      return $?
      ;;
    *)
      return 127
      ;;
  esac
}

resolve_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    command -v timeout
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    command -v gtimeout
    return 0
  fi
  return 1
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  if [ -n "${TIMEOUT_BIN:-}" ]; then
    "$TIMEOUT_BIN" "$timeout_seconds" "$@"
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    proc = subprocess.run(cmd, timeout=timeout)
    raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
PY
    return $?
  fi

  "$@"
  return $?
}

read_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    FAILURES=0
    LAST_REPAIR=0
    REPAIRS_THIS_INCIDENT=0
    RESCUE_ANNOUNCED=0
  fi

  : "${FAILURES:=0}"
  : "${LAST_REPAIR:=0}"
  : "${REPAIRS_THIS_INCIDENT:=0}"
  : "${RESCUE_ANNOUNCED:=0}"
}

write_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" <<STATEEOF
FAILURES=$FAILURES
LAST_REPAIR=$LAST_REPAIR
REPAIRS_THIS_INCIDENT=$REPAIRS_THIS_INCIDENT
RESCUE_ANNOUNCED=$RESCUE_ANNOUNCED
STATEEOF
}

latest_telegram_update_id() {
  if [ -z "$BOT_TOKEN" ]; then
    echo "0"
    return 0
  fi

  curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" \
    -d limit=1 -d offset=-1 \
    | jq -r '.result[-1].update_id // 0' 2>/dev/null || echo "0"
}

read_rescue_offset() {
  if [ -f "$RESCUE_OFFSET_FILE" ]; then
    cat "$RESCUE_OFFSET_FILE"
  else
    echo "0"
  fi
}

write_rescue_offset() {
  mkdir -p "$(dirname "$RESCUE_OFFSET_FILE")"
  echo "$1" > "$RESCUE_OFFSET_FILE"
}

prime_rescue_offset() {
  local last_id
  last_id=$(latest_telegram_update_id)
  write_rescue_offset $((last_id + 1))
}

fetch_rescue_command() {
  if [ -z "$BOT_TOKEN" ]; then
    return 1
  fi

  local offset
  offset=$(read_rescue_offset)

  local updates
  updates=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" \
    -d offset="$offset" -d timeout=0 2>/dev/null || true)

  local last_id
  last_id=$(printf "%s" "$updates" | jq -r '.result[-1].update_id // empty' 2>/dev/null || true)
  if [ -n "$last_id" ]; then
    write_rescue_offset $((last_id + 1))
  fi

  local cmd
  cmd=$(printf "%s" "$updates" | jq -r --arg prefix "$RESCUE_COMMAND_PREFIX" --arg chat "$CHAT_ID" '
    [.result[]
     | select((.message.chat.id | tostring) == $chat)
     | (.message.text // empty)]
    | reverse
    | map(select(startswith($prefix)))
    | .[0] // empty
  ' 2>/dev/null || true)

  if [ -z "$cmd" ]; then
    return 1
  fi

  cmd="${cmd#"$RESCUE_COMMAND_PREFIX"}"
  cmd="${cmd# }"
  if [ -z "$cmd" ]; then
    return 2
  fi

  echo "$cmd"
  return 0
}

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "Another watchdog run is active (PID $lock_pid), skipping"
      return 1
    fi
    rm -f "$LOCK_FILE"
  fi

  mkdir -p "$(dirname "$LOCK_FILE")"
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
  return 0
}

write_runtime_tg_helper() {
  cat > "$TG_HELPER" <<'HELPEREOF'
#!/usr/bin/env bash
# Telegram helper for Codex emergency repair

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
STANDALONE_HELPER="$OPENCLAW_HOME/bin/tg-helper.sh"

if [ -f "$STANDALONE_HELPER" ]; then
  # shellcheck disable=SC1090
  source "$STANDALONE_HELPER"
  return 0 2>/dev/null || true
fi

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"
TG_SUFFIX="${TG_SUFFIX:--codexrecov}"
TG_HEALTH_URL="${TG_HEALTH_URL:-http://127.0.0.1:18789}"

# Send a one-way status update.
tg_send() {
  if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then return 1; fi
  local msg="$1"
  if [ -n "$TG_SUFFIX" ] && [[ "$msg" != *"$TG_SUFFIX" ]]; then
    msg="${msg}
${TG_SUFFIX}"
  fi
  curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT" -d text="$msg" -d parse_mode="Markdown" >/dev/null 2>&1
}

# Ask a question and wait for a reply from the same Telegram chat.
tg_ask() {
  if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then echo ""; return 1; fi

  local last_update
  last_update=$(curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" \
    -d limit=1 -d offset=-1 | jq -r '.result[-1].update_id // 0' 2>/dev/null)
  local offset=$((last_update + 1))

  local qmsg="$1"
  if [ -n "$TG_SUFFIX" ] && [[ "$qmsg" != *"$TG_SUFFIX" ]]; then
    qmsg="${qmsg}
${TG_SUFFIX}"
  fi
  curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT" -d text="$qmsg" -d parse_mode="Markdown" >/dev/null 2>&1

  local i
  for i in $(seq 1 24); do
    sleep 5
    if curl -s --max-time 2 "$TG_HEALTH_URL" >/dev/null 2>&1; then
      tg_send "🟢 Gateway came back on its own! Stopping repair."
      echo ""
      return 1
    fi

    local payload reply
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
HELPEREOF

  chmod +x "$TG_HELPER"
}

run_watchdog() {
  load_config
  mkdir -p "$LOG_DIR"
  load_dotenv

  BOT_TOKEN="$(printenv "$TELEGRAM_BOT_TOKEN_ENV" 2>/dev/null || true)"
  if [ -z "$CHAT_ID" ]; then
    log "telegram_chat_id missing in config; watchdog will continue without Telegram notifications"
  fi

  if ! acquire_lock; then
    return 0
  fi

  read_state

  TIMEOUT_BIN="$(resolve_timeout_bin 2>/dev/null || true)"
  if [ -z "${TIMEOUT_BIN:-}" ]; then
    if [ ! -f "$TIMEOUT_WARN_FILE" ]; then
      log "timeout utility not found; using python3 timeout fallback for Codex runs"
      : > "$TIMEOUT_WARN_FILE"
    fi
  else
    rm -f "$TIMEOUT_WARN_FILE"
  fi

  if curl -s --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    if [ "$FAILURES" -gt 0 ]; then
      log "Gateway recovered after $FAILURES failure(s)"
      if [ "$REPAIRS_THIS_INCIDENT" -gt 0 ]; then
        notify_telegram "🟢 *Gateway recovered* after $REPAIRS_THIS_INCIDENT auto-repair attempt(s). Check \`$RECOVERY_LOG\` for details."
      fi
    fi

    FAILURES=0
    REPAIRS_THIS_INCIDENT=0
    RESCUE_ANNOUNCED=0
    rm -f "$RESCUE_OFFSET_FILE"
    write_state
    return 0
  fi

  FAILURES=$((FAILURES + 1))
  log "Health check failed (failure #$FAILURES)"
  write_state

  if [ "$FAILURES" -lt "$MAX_FAILURES" ]; then
    return 0
  fi

  local threshold_minutes
  threshold_minutes=$((MAX_FAILURES * 5))
  if [ "$FAILURES" -eq "$MAX_FAILURES" ]; then
    log "Gateway down for $MAX_FAILURES consecutive checks — initiating recovery"
    notify_telegram "🔴 *Gateway down for ~${threshold_minutes} minutes.* Service manager couldn't auto-restart it. Launching Codex CLI to diagnose and repair..."
  fi

  local coding_agent agent_type agent_bin agent_label
  coding_agent="$(resolve_coding_agent 2>/dev/null || true)"
  agent_type="${coding_agent%%:*}"
  agent_bin="${coding_agent#*:}"
  case "$agent_type" in
    codex)
      agent_label="Codex"
      ;;
    claude)
      agent_label="Claude Code"
      ;;
    *)
      agent_type="none"
      agent_bin=""
      agent_label="coding agent"
      ;;
  esac

  if [ "$REPAIRS_THIS_INCIDENT" -ge "$MAX_REPAIRS_PER_INCIDENT" ]; then
    if [ "$RESCUE_ANNOUNCED" -eq 0 ]; then
      log "Max repairs reached ($MAX_REPAIRS_PER_INCIDENT) — entering Telegram rescue mode"
      prime_rescue_offset
      notify_telegram_codex "🚨 *Auto-repair failed after $MAX_REPAIRS_PER_INCIDENT attempts.* Gateway is still down.

Rescue mode is now active.
Send commands in this chat using:
\`$RESCUE_COMMAND_PREFIX <what to do>\`

Examples:
\`$RESCUE_COMMAND_PREFIX run doctor and summarize\`
\`$RESCUE_COMMAND_PREFIX inspect gateway.err.log and fix startup crash\`

I will route each command to the configured coding agent while the gateway is down."
      RESCUE_ANNOUNCED=1
      write_state
      return 0
    fi

    local rescue_cmd
    rescue_cmd="$(fetch_rescue_command || true)"
    if [ -z "${rescue_cmd:-}" ]; then
      log "Rescue mode active — waiting for Telegram command prefix '$RESCUE_COMMAND_PREFIX'"
      return 0
    fi

    local attempt_stamp codex_log_file rescue_prompt repair_output repair_exit
    attempt_stamp=$(date -u +"%Y%m%dT%H%M%SZ")
    codex_log_file="$LOG_DIR/watchdog-codex-rescue-${attempt_stamp}.log"

    log "Rescue command received: $rescue_cmd"
    notify_telegram_codex "🛠️ Running rescue command via ${agent_label}: \`${rescue_cmd}\`"

    rescue_prompt="OpenClaw gateway is still down after ${MAX_REPAIRS_PER_INCIDENT} auto-attempts.

Operator command from Telegram:
${rescue_cmd}

Objective:
- Execute this command intent and continue troubleshooting until gateway is healthy or timeout.

Hard success check:
- curl -s --max-time 5 ${HEALTH_URL} succeeds.

Rules:
- No destructive ops.
- Back up files before edits.
- Do not modify SOUL.md, USER.md, AGENTS.md, MEMORY.md, memory/*.md.
- Log exact diagnosis + actions + result in output."

    if [ "$agent_type" = "none" ] || [ -z "$agent_bin" ] || [ ! -x "$agent_bin" ]; then
      repair_output="no coding agent found; install Codex or Claude Code"
      repair_exit=127
      notify_no_agent_found
    else
      repair_output=$(run_coding_agent_prompt "$agent_type" "$agent_bin" "$RESCUE_CODEX_TIMEOUT" "$rescue_prompt" 2>&1)
      repair_exit=$?
    fi

    {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] rescue exit=$repair_exit timeout=${RESCUE_CODEX_TIMEOUT}s"
      echo "command=$rescue_cmd"
      echo "$repair_output"
    } > "$codex_log_file"

    log "Rescue Codex output saved: $codex_log_file (exit=$repair_exit)"

    LAST_REPAIR=$(date +%s)
    write_state

    sleep 8
    if curl -s --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      log "✅ Rescue command recovered gateway"
      notify_telegram_codex "✅ Rescue command recovered gateway. Log: \`$codex_log_file\`"
    else
      log "❌ Rescue command did not recover gateway yet"
      notify_telegram_codex "❌ Gateway still down after rescue command. Send another command with \`$RESCUE_COMMAND_PREFIX ...\`\nLog: \`$codex_log_file\`"
    fi

    return 0
  fi

  local now elapsed
  now=$(date +%s)
  elapsed=$((now - LAST_REPAIR))
  if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
    local remaining
    remaining=$(((COOLDOWN_SECONDS - elapsed) / 60))
    log "Cooldown active — last repair was ${elapsed}s ago, waiting ${remaining}m more"
    return 0
  fi

  write_runtime_tg_helper

  local attempt_num attempt_stamp codex_log_file repair_prompt repair_output repair_exit
  local openclaw_bin node_bin
  openclaw_bin="$(resolve_openclaw_bin)"
  node_bin="$(resolve_node_bin)"

  attempt_num=$((REPAIRS_THIS_INCIDENT + 1))
  attempt_stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  codex_log_file="$LOG_DIR/watchdog-codex-attempt-${attempt_num}-${attempt_stamp}.log"

  log "Launching ${agent_label} repair attempt #$attempt_num"

  repair_prompt="OpenClaw gateway has been unresponsive for 10+ minutes and hasn't self-recovered.

You have Telegram helper functions. Source them first:
export OPENCLAW_HOME=\"${OPENCLAW_HOME}\"
export TG_TOKEN=\"${BOT_TOKEN}\"
export TG_CHAT=\"${CHAT_ID}\"
export TG_SUFFIX=\"${CODEX_RECOV_SUFFIX}\"
export TG_HEALTH_URL=\"${HEALTH_URL}\"
source ${TG_HELPER}

Then use:
- tg_send \"message\" for status updates
- tg_ask \"question?\" only if genuinely ambiguous

Rules: Just fix it. Don't ask permission. Back up config before changes. Operator can revert.

Objective:
- Keep going until gateway is healthy or timeout.
- Health success = curl to ${HEALTH_URL} succeeds 3 times in a row with 10s spacing.

Required loop:
1. tg_send \"🔧 Repair attempt #${attempt_num} starting.\"
2. Gather state:
   - pgrep -f 'openclaw.*gateway' || echo 'not running'
   - launchctl list | rg 'ai.openclaw.gateway' || true
   - systemctl --user status openclaw-gateway || true
   - tail -120 ${OPENCLAW_HOME}/logs/gateway.log
   - tail -120 ${OPENCLAW_HOME}/logs/gateway.err.log
3. If CLI works, run:
   - ${openclaw_bin} doctor
   - ${openclaw_bin} doctor --fix --non-interactive
   - ${openclaw_bin} gateway restart
4. If CLI is broken or startup crashes (especially SyntaxError in dist files):
   - inspect referenced dist file
   - repair or roll back safely
   - run ${node_bin} --check on changed reply-prefix-*.js files
   - restart service with openclaw gateway restart, launchctl kickstart, or systemctl --user restart
5. Verify health 3x (10s apart). If healthy, stop.
6. If still unhealthy, send tg_send with new hypothesis and repeat from step 2.

Common failure classes:
- invalid config properties or schema violations
- port conflicts/stale PID
- service manager unit not loaded
- broken dist JS patch (e.g. duplicate declarations, missing imports)

NEVER modify: SOUL.md, USER.md, AGENTS.md, MEMORY.md, memory/*.md
NEVER delete data or logs.

When done, append to ${RECOVERY_LOG}:
## Recovery - \$(date '+%Y-%m-%d %H:%M:%S')
- **Attempt:** #${attempt_num}
- **Root cause:** [what you found]
- **Fix applied:** [what you did]
- **Result:** [recovered / still down]

Then: tg_send \"[✅ or ❌] Repair #${attempt_num} complete. [1-line summary]\""

  if [ "$agent_type" = "none" ] || [ -z "$agent_bin" ] || [ ! -x "$agent_bin" ]; then
    repair_output="no coding agent found; install Codex or Claude Code"
    repair_exit=127
    notify_no_agent_found
  else
    repair_output=$(run_coding_agent_prompt "$agent_type" "$agent_bin" "$CODEX_TIMEOUT" "$repair_prompt" 2>&1)
    repair_exit=$?
  fi

  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] attempt=$attempt_num exit=$repair_exit timeout=${CODEX_TIMEOUT}s"
    echo "$repair_output"
  } > "$codex_log_file"

  log "Codex attempt #$attempt_num output saved: $codex_log_file (exit=$repair_exit)"

  if [ "$repair_exit" -eq 124 ]; then
    log "Codex attempt #$attempt_num hit timeout (${CODEX_TIMEOUT}s)"
  fi

  LAST_REPAIR=$(date +%s)
  REPAIRS_THIS_INCIDENT=$((REPAIRS_THIS_INCIDENT + 1))
  write_state

  sleep 10
  if curl -s --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    log "✅ Repair successful on attempt #$REPAIRS_THIS_INCIDENT"
    notify_telegram "🟢 *Auto-repair successful!* Gateway is back online (attempt #$REPAIRS_THIS_INCIDENT)."
  else
    log "❌ Repair attempt #$REPAIRS_THIS_INCIDENT failed — gateway still down"
    if [ "$REPAIRS_THIS_INCIDENT" -lt "$MAX_REPAIRS_PER_INCIDENT" ]; then
      local cooldown_minutes
      cooldown_minutes=$((COOLDOWN_SECONDS / 60))
      notify_telegram "🔴 *Auto-repair attempt #$REPAIRS_THIS_INCIDENT didn't fix it.* Will retry in ${cooldown_minutes} min."
    fi
  fi

  log "Repair attempt #$REPAIRS_THIS_INCIDENT complete"
  return 0
}

main() {
  run_watchdog "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [ "${WATCHDOG_SKIP_MAIN:-0}" != "1" ]; then
  main "$@"
fi
