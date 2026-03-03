#!/usr/bin/env bash
# MEMORY BACKUP - local git only, NEVER pushed to remote.
# Your daily notes, session summaries, and MEMORY.md are private.
# This backup protects against local corruption only.
set -euo pipefail
shopt -s nullglob

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
CONFIG_FILE="${OPENCLAW_BACKUP_CONFIG:-$OPENCLAW_HOME/backup.json}"
TIMESTAMP=$(date +%Y-%m-%d)

config_get() {
  local key="$1"
  local default_value="$2"

  python3 - "$CONFIG_FILE" "$key" "$default_value" <<'PY'
import json
import os
import sys

config_file, key, default_value = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(os.path.expanduser(config_file), "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(default_value)
    sys.exit(0)

value = data
for part in key.split('.'):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print(default_value)
        sys.exit(0)

if value is None:
    print(default_value)
else:
    print(str(value))
PY
}

expand_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(os.path.expandvars(os.path.expanduser(sys.argv[1]))))
PY
}

BACKUP_DIR_RAW="$(config_get "memory_backup_dir" "~/backups/openclaw-memory")"
BACKUP_DIR="$(expand_path "$BACKUP_DIR_RAW")"

mkdir -p "$BACKUP_DIR/memory" "$BACKUP_DIR/life" "$BACKUP_DIR/sessions"

cp "$OPENCLAW_HOME/workspace/MEMORY.md" "$BACKUP_DIR/" 2>/dev/null || true
rsync -a --delete "$OPENCLAW_HOME/workspace/memory/" "$BACKUP_DIR/memory/" 2>/dev/null || true
rsync -a --delete "$OPENCLAW_HOME/workspace/life/" "$BACKUP_DIR/life/" 2>/dev/null || true

for agent_dir in "$OPENCLAW_HOME"/agents/*/; do
  [ -d "$agent_dir" ] || continue
  agent_name="$(basename "$agent_dir")"
  mkdir -p "$BACKUP_DIR/sessions/$agent_name"
  rsync -a --delete "$agent_dir/qmd/sessions/" "$BACKUP_DIR/sessions/$agent_name/" 2>/dev/null || true
done

cp "$HOME/.cache/qmd/index.sqlite" "$BACKUP_DIR/qmd-index.sqlite" 2>/dev/null || true

cd "$BACKUP_DIR"
if [ ! -d .git ]; then
  git init -q
fi
if ! git rev-parse --verify main >/dev/null 2>&1; then
  git checkout -B main >/dev/null 2>&1 || true
else
  git checkout main >/dev/null 2>&1 || true
fi

git add -A
git diff --cached --quiet && exit 0
git commit -m "memory: $TIMESTAMP" --quiet
# NO git push - local only
