#!/usr/bin/env bash

set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
BIN_DIR="$OPENCLAW_HOME/bin"
CONFIG_PATH="${OPENCLAW_WATCHDOG_CONFIG:-$OPENCLAW_HOME/watchdog.json}"
LAUNCHD_DEST="$HOME/Library/LaunchAgents/ai.openclaw.watchdog.plist"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
PURGE_CONFIG=0

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--purge]

Flags:
  --purge  Also remove ~/.openclaw/watchdog.json
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)
      PURGE_CONFIG=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "uninstall: unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin)
    launchctl bootout "gui/$UID" "$LAUNCHD_DEST" >/dev/null 2>&1 || true
    rm -f "$LAUNCHD_DEST"
    ;;
  Linux)
    systemctl --user disable --now openclaw-watchdog.timer >/dev/null 2>&1 || true
    systemctl --user disable --now openclaw-watchdog.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_USER_DIR/openclaw-watchdog.service" "$SYSTEMD_USER_DIR/openclaw-watchdog.timer"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ;;
  *)
    echo "uninstall: unsupported platform $(uname -s), skipped service removal" >&2
    ;;
esac

rm -f "$BIN_DIR/watchdog.sh" "$BIN_DIR/tg-helper.sh"

if [ "$PURGE_CONFIG" -eq 1 ]; then
  rm -f "$CONFIG_PATH"
fi

echo "OpenClaw watchdog uninstalled."
