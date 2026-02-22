#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
BIN_DIR="$OPENCLAW_HOME/bin"
CONFIG_PATH="${OPENCLAW_WATCHDOG_CONFIG:-$OPENCLAW_HOME/watchdog.json}"
LAUNCHD_DEST="$HOME/Library/LaunchAgents/ai.openclaw.watchdog.plist"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
TMP_REPO=""

SETUP_ONLY=0
QUIET_MODE=0
CHECK_ONLY=0

usage() {
  cat <<'USAGE'
Usage: install.sh [--setup] [--quiet] [--check]

Flags:
  --setup  Run setup wizard and write ~/.openclaw/watchdog.json
  --quiet  Non-interactive setup (requires OPENCLAW_WATCHDOG_CHAT_ID)
  --check  Verify install only, no changes made
USAGE
}

log() {
  printf '%s\n' "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "install: required command missing: $cmd" >&2
    exit 1
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --setup)
        SETUP_ONLY=1
        ;;
      --quiet)
        QUIET_MODE=1
        ;;
      --check)
        CHECK_ONLY=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "install: unknown flag: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

cleanup_tmp_repo() {
  if [ -n "$TMP_REPO" ] && [ -d "$TMP_REPO" ]; then
    rm -rf "$TMP_REPO"
  fi
}

fetch_if_needed() {
  if [ -f "$SCRIPT_DIR/scripts/watchdog.sh" ]; then
    return 0
  fi

  require_cmd curl
  require_cmd tar

  TMP_REPO=$(mktemp -d)
  trap cleanup_tmp_repo EXIT

  curl -fsSL "https://codeload.github.com/bkochavy/openclaw-watchdog/tar.gz/main" | tar -xz -C "$TMP_REPO"

  SCRIPT_DIR="$(find "$TMP_REPO" -maxdepth 1 -type d -name 'openclaw-watchdog-*' | head -1)"
  if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/scripts/watchdog.sh" ]; then
    echo "install: failed to fetch watchdog scripts from GitHub" >&2
    exit 1
  fi
}

install_scripts() {
  mkdir -p "$BIN_DIR"
  mkdir -p "$OPENCLAW_HOME/logs"
  mkdir -p "$OPENCLAW_HOME/workspace/memory"

  install -m 0755 "$SCRIPT_DIR/scripts/watchdog.sh" "$BIN_DIR/watchdog.sh"
  install -m 0755 "$SCRIPT_DIR/scripts/lib/tg-helper.sh" "$BIN_DIR/tg-helper.sh"
}

run_setup_wizard() {
  require_cmd python3

  python3 - "$CONFIG_PATH" "$QUIET_MODE" <<'PY'
import json
import os
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1]).expanduser()
quiet_mode = sys.argv[2] == "1"


def env_or_default(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value if value else default


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    raw = input(f"{label}{suffix}: ").strip()
    if raw:
      return raw
    return default

health_default = "http://127.0.0.1:18789"
token_env_default = "TELEGRAM_BOT_TOKEN_AVA"
max_failures_default = 2

if quiet_mode:
    health_url = env_or_default("OPENCLAW_WATCHDOG_HEALTH_URL", health_default)
    token_env = env_or_default("OPENCLAW_WATCHDOG_TOKEN_ENV", token_env_default)
    chat_id = os.environ.get("OPENCLAW_WATCHDOG_CHAT_ID", "").strip()
    max_failures_raw = env_or_default("OPENCLAW_WATCHDOG_MAX_FAILURES", str(max_failures_default))

    if not chat_id:
        print("install: OPENCLAW_WATCHDOG_CHAT_ID is required in --quiet mode", file=sys.stderr)
        raise SystemExit(2)

    try:
        max_failures = int(max_failures_raw)
    except ValueError:
        max_failures = max_failures_default
else:
    print("OpenClaw Watchdog Setup")
    print("-----------------------")
    health_url = prompt("1) OpenClaw health URL", health_default)
    token_env = prompt("2) Telegram bot token env var name", token_env_default)

    chat_id = ""
    while not chat_id:
        chat_id = prompt("3) Telegram chat ID (required)", "")
        if not chat_id:
            print("Telegram chat ID is required.")

    max_failures_raw = prompt("4) Max failures before repair trigger", str(max_failures_default))
    try:
        max_failures = int(max_failures_raw)
    except ValueError:
        max_failures = max_failures_default

    print("")
    print(f"Preview: After {max_failures} failures (~{max_failures * 5} min), the coding agent will attempt repair and notify chat ID {chat_id}.")
    confirm = input("Confirm and write config? [y/N]: ").strip().lower()
    if confirm not in {"y", "yes"}:
        print("Setup canceled.")
        raise SystemExit(3)

config = {
    "health_url": health_url,
    "telegram_bot_token_env": token_env,
    "telegram_chat_id": chat_id,
    "max_failures": max_failures,
    "cooldown_seconds": 1800,
    "max_repairs_per_incident": 3,
    "codex_timeout_seconds": 180,
    "rescue_command_timeout_seconds": 420,
    "rescue_command_prefix": "/codex",
    "recovery_log": "~/.openclaw/workspace/memory/recovery-log.md",
    "state_file": "/tmp/openclaw-watchdog-state",
    "lock_file": "/tmp/openclaw-watchdog.lock",
    "codex_model": "gpt-5.3-codex",
    "codex_bin": "",
    "claude_bin": ""
}

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
print(f"Wrote config: {config_path}")
PY
}

install_launchd() {
  local watchdog_bin="$BIN_DIR/watchdog.sh"
  local log_file="$OPENCLAW_HOME/logs/watchdog.log"
  local err_file="$OPENCLAW_HOME/logs/watchdog.err.log"

  mkdir -p "$(dirname "$LAUNCHD_DEST")"
  sed \
    -e "s|__WATCHDOG_BIN__|$watchdog_bin|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__LOG_FILE__|$log_file|g" \
    -e "s|__ERR_FILE__|$err_file|g" \
    "$SCRIPT_DIR/templates/launchd/ai.openclaw.watchdog.plist.template" > "$LAUNCHD_DEST"

  launchctl bootout "gui/$UID" "$LAUNCHD_DEST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$LAUNCHD_DEST"
  launchctl enable "gui/$UID/ai.openclaw.watchdog" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$UID/ai.openclaw.watchdog" >/dev/null 2>&1 || true
}

install_systemd() {
  mkdir -p "$SYSTEMD_USER_DIR"

  install -m 0644 "$SCRIPT_DIR/templates/systemd/openclaw-watchdog.service" \
    "$SYSTEMD_USER_DIR/openclaw-watchdog.service"
  install -m 0644 "$SCRIPT_DIR/templates/systemd/openclaw-watchdog.timer" \
    "$SYSTEMD_USER_DIR/openclaw-watchdog.timer"

  systemctl --user daemon-reload
  systemctl --user enable --now openclaw-watchdog.timer
}

check_install() {
  local failures=0

  if [ ! -x "$BIN_DIR/watchdog.sh" ]; then
    echo "check: missing executable $BIN_DIR/watchdog.sh" >&2
    failures=$((failures + 1))
  fi

  if [ ! -x "$BIN_DIR/tg-helper.sh" ]; then
    echo "check: missing executable $BIN_DIR/tg-helper.sh" >&2
    failures=$((failures + 1))
  fi

  if [ ! -f "$CONFIG_PATH" ]; then
    echo "check: missing config $CONFIG_PATH" >&2
    failures=$((failures + 1))
  fi

  if [ -f "$CONFIG_PATH" ]; then
    require_cmd jq
    local chat_id
    chat_id=$(jq -r '.telegram_chat_id // empty' "$CONFIG_PATH")
    if [ -z "$chat_id" ]; then
      echo "check: telegram_chat_id is empty in $CONFIG_PATH" >&2
      failures=$((failures + 1))
    fi
  fi

  case "$(uname -s)" in
    Darwin)
      if [ ! -f "$LAUNCHD_DEST" ]; then
        echo "check: missing launchd plist $LAUNCHD_DEST" >&2
        failures=$((failures + 1))
      elif ! launchctl print "gui/$UID/ai.openclaw.watchdog" >/dev/null 2>&1; then
        echo "check: launchd job ai.openclaw.watchdog is not loaded" >&2
        failures=$((failures + 1))
      fi
      ;;
    Linux)
      if ! systemctl --user is-enabled openclaw-watchdog.timer >/dev/null 2>&1; then
        echo "check: openclaw-watchdog.timer is not enabled" >&2
        failures=$((failures + 1))
      fi
      if ! systemctl --user is-active openclaw-watchdog.timer >/dev/null 2>&1; then
        echo "check: openclaw-watchdog.timer is not active" >&2
        failures=$((failures + 1))
      fi
      ;;
    *)
      echo "check: unsupported platform $(uname -s), skipped service-manager checks" >&2
      ;;
  esac

  if [ "$failures" -gt 0 ]; then
    return 1
  fi

  return 0
}

main() {
  parse_args "$@"

  if [ "$QUIET_MODE" -eq 0 ] && [ -n "${OPENCLAW_WATCHDOG_CHAT_ID:-}" ]; then
    QUIET_MODE=1
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    check_install
    log "Install check passed."
    exit 0
  fi

  fetch_if_needed
  install_scripts

  if [ "$SETUP_ONLY" -eq 1 ] || [ ! -f "$CONFIG_PATH" ]; then
    run_setup_wizard
  fi

  case "$(uname -s)" in
    Darwin)
      install_launchd
      ;;
    Linux)
      install_systemd
      ;;
    *)
      echo "install: unsupported platform $(uname -s). Service setup skipped." >&2
      ;;
  esac

  check_install

  log "✅ Watchdog active. Checks gateway every 5 min. Codex repairs after ~10 min down."
}

main "$@"
