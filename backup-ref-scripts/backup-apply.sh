#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_BACKUP_CONFIG="${OPENCLAW_BACKUP_CONFIG:-$HOME/.openclaw/backup.json}"
BACKUP_BIN="${BACKUP_BIN:-$HOME/.openclaw/bin/backup.sh}"
MEMORY_BIN="${MEMORY_BIN:-$HOME/.openclaw/bin/backup-memory.sh}"

"$BACKUP_BIN" --config "$OPENCLAW_BACKUP_CONFIG" "$@"
"$MEMORY_BIN" --config "$OPENCLAW_BACKUP_CONFIG"
