#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
BIN_DIR="$OPENCLAW_HOME/bin"
LIB_DIR="$BIN_DIR/lib"
CONFIG_PATH="${OPENCLAW_SENTINEL_CONFIG:-$OPENCLAW_HOME/sentinel.json}"
LAUNCHD_DEST="$HOME/Library/LaunchAgents/ai.openclaw.sentinel.plist"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
TMP_REPO=""

SETUP_ONLY=0
QUIET_MODE=0
CHECK_ONLY=0
MIGRATE=0

usage() {
  cat <<'USAGE'
Usage: install.sh [--setup] [--quiet] [--check] [--migrate]

Flags:
  --setup    Run setup wizard and write ~/.openclaw/sentinel.json
  --quiet    Non-interactive setup defaults (OPENCLAW_SENTINEL_CHAT_ID optional)
  --check    Verify installation only; make no changes
  --migrate  Migrate legacy watchdog.json/backup.json into sentinel.json
USAGE
}

log() { printf '%s\n' "$*"; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { printf 'install: required command missing: %s\n' "$cmd" >&2; exit 1; }
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then return 0; fi
  printf 'install: jq is required\n' >&2
  printf '  Ubuntu/Debian: sudo apt install jq\n' >&2
  printf '  macOS:         brew install jq\n' >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --setup) SETUP_ONLY=1 ;;
      --quiet) QUIET_MODE=1 ;;
      --check) CHECK_ONLY=1 ;;
      --migrate) MIGRATE=1 ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'install: unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done
}

cleanup_tmp_repo() { [ -n "$TMP_REPO" ] && [ -d "$TMP_REPO" ] && rm -rf "$TMP_REPO"; }

fetch_if_needed() {
  [ -f "$SCRIPT_DIR/scripts/sentinel.sh" ] && return 0
  require_cmd curl
  require_cmd tar
  TMP_REPO="$(mktemp -d)"
  trap cleanup_tmp_repo EXIT
  curl -fsSL "https://codeload.github.com/bkochavy/openclaw-sentinel/tar.gz/main" | tar -xz -C "$TMP_REPO"
  SCRIPT_DIR="$(find "$TMP_REPO" -maxdepth 1 -type d -name 'openclaw-sentinel-*' | head -1)"
  [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/scripts/sentinel.sh" ] || { printf 'install: failed to fetch sentinel scripts\n' >&2; exit 1; }
}

write_default_config() {
  mkdir -p "$(dirname "$CONFIG_PATH")"
  if [ -f "$SCRIPT_DIR/sentinel.example.json" ]; then
    cp "$SCRIPT_DIR/sentinel.example.json" "$CONFIG_PATH"
  else
    cat > "$CONFIG_PATH" <<'EOFJSON'
{
  "health_url": "http://127.0.0.1:18789/healthz",
  "check_interval_seconds": 300
}
EOFJSON
  fi
}

run_setup_wizard() {
  local health_url token_env chat_id tmp
  if [ ! -f "$CONFIG_PATH" ]; then write_default_config; fi

  if [ "$QUIET_MODE" -eq 1 ]; then
    health_url="${OPENCLAW_SENTINEL_HEALTH_URL:-http://127.0.0.1:18789/healthz}"
    token_env="${OPENCLAW_SENTINEL_TOKEN_ENV:-TELEGRAM_BOT_TOKEN_AVA}"
    chat_id="${OPENCLAW_SENTINEL_CHAT_ID:-}"
  else
    printf 'OpenClaw Sentinel Setup\n'
    printf '-----------------------\n'
    read -r -p "1) Health URL [http://127.0.0.1:18789/healthz]: " health_url
    read -r -p "2) Telegram token env var [TELEGRAM_BOT_TOKEN_AVA]: " token_env
    read -r -p "3) Telegram chat ID (optional): " chat_id
    health_url="${health_url:-http://127.0.0.1:18789/healthz}"
    token_env="${token_env:-TELEGRAM_BOT_TOKEN_AVA}"
  fi

  tmp="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")"
  if ! jq --arg health "$health_url" --arg env "$token_env" --arg chat "$chat_id" '
    .health_url = $health
    | .notifications.telegram_bot_token_env = $env
    | .notifications.telegram_chat_id = $chat
  ' "$CONFIG_PATH" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$CONFIG_PATH"; then
    rm -f "$tmp"
    return 1
  fi
}

install_scripts() {
  mkdir -p "$BIN_DIR" "$LIB_DIR" "$OPENCLAW_HOME/logs" "$OPENCLAW_HOME/state" "$OPENCLAW_HOME/workspace/memory"
  install -m 0755 "$SCRIPT_DIR/scripts/sentinel.sh" "$BIN_DIR/sentinel.sh"
  for file in "$SCRIPT_DIR"/scripts/lib/*.sh; do install -m 0755 "$file" "$LIB_DIR/$(basename "$file")"; done
  install -m 0755 "$SCRIPT_DIR/scripts/lib/tg-helper.sh" "$BIN_DIR/tg-helper.sh"
}

unload_legacy_watchdog_launchd_plist() {
  local plist="$HOME/Library/LaunchAgents/ai.openclaw.watchdog.plist"
  [ -f "$plist" ] || return 0

  if rg -q "<key>StartInterval</key>" "$plist" && rg -q "<key>StartCalendarInterval</key>" "$plist"; then
    perl -0pi -e 's/\n\s*<key>StartCalendarInterval<\/key>\n\s*<array>.*?<\/array>//s' "$plist"
    log "install: removed duplicate StartCalendarInterval from legacy watchdog plist"
  fi
}

unload_legacy_services() {
  case "$(uname -s)" in
    Darwin)
      unload_legacy_watchdog_launchd_plist
      launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/ai.openclaw.watchdog.plist" >/dev/null 2>&1 || true
      launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/ai.openclaw.sentinel.plist" >/dev/null 2>&1 || true
      ;;
    Linux)
      systemctl --user disable --now openclaw-watchdog.timer >/dev/null 2>&1 || true
      systemctl --user disable --now openclaw-watchdog.service >/dev/null 2>&1 || true
      systemctl --user disable --now openclaw-backup.timer >/dev/null 2>&1 || true
      systemctl --user disable --now openclaw-backup.service >/dev/null 2>&1 || true
      ;;
  esac
}

install_launchd() {
  local sentinel_bin="$BIN_DIR/sentinel.sh" log_file="$OPENCLAW_HOME/logs/sentinel.log" err_file="$OPENCLAW_HOME/logs/sentinel.err.log"
  mkdir -p "$(dirname "$LAUNCHD_DEST")"
  sed -e "s|__SENTINEL_BIN__|$sentinel_bin|g" -e "s|__HOME__|$HOME|g" -e "s|__LOG_FILE__|$log_file|g" -e "s|__ERR_FILE__|$err_file|g" \
    "$SCRIPT_DIR/templates/launchd/ai.openclaw.sentinel.plist.template" > "$LAUNCHD_DEST"
  launchctl bootout "gui/$UID" "$LAUNCHD_DEST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$LAUNCHD_DEST"
  launchctl enable "gui/$UID/ai.openclaw.sentinel" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$UID/ai.openclaw.sentinel" >/dev/null 2>&1 || true
}

install_systemd() {
  local sentinel_bin="$BIN_DIR/sentinel.sh"
  mkdir -p "$SYSTEMD_USER_DIR"
  sed -e "s|__SENTINEL_BIN__|$sentinel_bin|g" \
    "$SCRIPT_DIR/templates/systemd/openclaw-sentinel.service" > "$SYSTEMD_USER_DIR/openclaw-sentinel.service"
  chmod 0644 "$SYSTEMD_USER_DIR/openclaw-sentinel.service"
  install -m 0644 "$SCRIPT_DIR/templates/systemd/openclaw-sentinel.timer" "$SYSTEMD_USER_DIR/openclaw-sentinel.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now openclaw-sentinel.timer
}

check_install() {
  local failures=0 lib
  [ -x "$BIN_DIR/sentinel.sh" ] || { printf 'check: missing executable %s\n' "$BIN_DIR/sentinel.sh" >&2; failures=$((failures + 1)); }
  [ -x "$BIN_DIR/tg-helper.sh" ] || { printf 'check: missing executable %s\n' "$BIN_DIR/tg-helper.sh" >&2; failures=$((failures + 1)); }
  for lib in backup-memory.sh backup.sh config.sh health.sh lock.sh notify.sh recovery.sh state.sh tg-helper.sh; do
    [ -x "$LIB_DIR/$lib" ] || { printf 'check: missing executable %s\n' "$LIB_DIR/$lib" >&2; failures=$((failures + 1)); }
  done
  [ -f "$CONFIG_PATH" ] || { printf 'check: missing config %s\n' "$CONFIG_PATH" >&2; failures=$((failures + 1)); }

  case "$(uname -s)" in
    Darwin)
      [ -f "$LAUNCHD_DEST" ] || { printf 'check: missing launchd plist %s\n' "$LAUNCHD_DEST" >&2; failures=$((failures + 1)); }
      launchctl print "gui/$UID/ai.openclaw.sentinel" >/dev/null 2>&1 || { printf 'check: launchd job ai.openclaw.sentinel is not loaded\n' >&2; failures=$((failures + 1)); }
      ;;
    Linux)
      systemctl --user is-enabled openclaw-sentinel.timer >/dev/null 2>&1 || { printf 'check: openclaw-sentinel.timer is not enabled\n' >&2; failures=$((failures + 1)); }
      systemctl --user is-active openclaw-sentinel.timer >/dev/null 2>&1 || { printf 'check: openclaw-sentinel.timer is not active\n' >&2; failures=$((failures + 1)); }
      ;;
  esac

  [ "$failures" -eq 0 ]
}

main() {
  parse_args "$@"
  ensure_jq
  fetch_if_needed

  if [ "$CHECK_ONLY" -eq 1 ]; then
    check_install
    log "Install check passed."
    exit 0
  fi

  install_scripts
  unload_legacy_services

  if [ "$MIGRATE" -eq 1 ]; then
    "$BIN_DIR/sentinel.sh" --migrate
  fi

  if [ "$SETUP_ONLY" -eq 1 ] || [ ! -f "$CONFIG_PATH" ]; then
    run_setup_wizard
  fi

  case "$(uname -s)" in
    Darwin) install_launchd ;;
    Linux) install_systemd ;;
    *) printf 'install: unsupported platform %s (service setup skipped)\n' "$(uname -s)" >&2 ;;
  esac

  check_install
  log "✅ OpenClaw sentinel installed and active."
}

main "$@"
