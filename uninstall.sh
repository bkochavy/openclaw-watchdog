#!/usr/bin/env bash

set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
BIN_DIR="$OPENCLAW_HOME/bin"
CONFIG_PATH="${OPENCLAW_SENTINEL_CONFIG:-$OPENCLAW_HOME/sentinel.json}"
LAUNCHD_DEST="$HOME/Library/LaunchAgents/ai.openclaw.sentinel.plist"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
PURGE_CONFIG=0

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--purge]

Flags:
  --purge  Also remove ~/.openclaw/sentinel.json
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge) PURGE_CONFIG=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'uninstall: unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin)
    launchctl bootout "gui/$UID" "$LAUNCHD_DEST" >/dev/null 2>&1 || true
    rm -f "$LAUNCHD_DEST"
    ;;
  Linux)
    systemctl --user disable --now openclaw-sentinel.timer >/dev/null 2>&1 || true
    systemctl --user disable --now openclaw-sentinel.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_USER_DIR/openclaw-sentinel.service" "$SYSTEMD_USER_DIR/openclaw-sentinel.timer"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ;;
  *)
    printf 'uninstall: unsupported platform %s, skipped service removal\n' "$(uname -s)" >&2
    ;;
esac

rm -f "$BIN_DIR/sentinel.sh" "$BIN_DIR/tg-helper.sh"
rm -rf "$BIN_DIR/lib"

if [ "$PURGE_CONFIG" -eq 1 ]; then
  rm -f "$CONFIG_PATH"
fi

printf 'OpenClaw sentinel uninstalled.\n'
