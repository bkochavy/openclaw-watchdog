#!/usr/bin/env bash
if [[ "$(uname -s)" == "Darwin" ]]; then
  export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
fi
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"
# Daily system config backup -> local git + optional GitHub push
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
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

config_list() {
  local key="$1"

  python3 - "$CONFIG_FILE" "$key" <<'PY'
import json
import os
import sys

config_file, key = sys.argv[1], sys.argv[2]

try:
    with open(os.path.expanduser(config_file), "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

value = data
for part in key.split('.'):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        sys.exit(0)

if isinstance(value, list):
    for item in value:
        print(str(item))
PY
}

expand_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(os.path.expandvars(os.path.expanduser(sys.argv[1]))))
PY
}

is_true() {
  case "${1}" in
    1|true|TRUE|True|yes|YES|Yes|y|Y|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

backup_env_file() {
  local source_file="$1"
  local target_file="$2"

  [ -f "$source_file" ] || return 0
  if is_true "$REDACT_ENV_VALUES"; then
    sed 's/=.*/=REDACTED/' "$source_file" > "$target_file"
  else
    cp "$source_file" "$target_file"
  fi
}

BACKUP_DIR_RAW="$(config_get "backup_dir" "~/backups/openclaw-system")"
BACKUP_DIR="$(expand_path "$BACKUP_DIR_RAW")"
GITHUB_REPO="$(config_get "github_repo" "")"
GITHUB_USER="$(config_get "github_user" "")"
TELEGRAM_BOT_TOKEN_ENV="$(config_get "telegram_bot_token_env" "TELEGRAM_BOT_TOKEN_AVA")"
TELEGRAM_CHAT_ID="$(config_get "telegram_chat_id" "")"
INCLUDE_SKILLS="$(config_get "include_skills" "true")"
INCLUDE_SCRIPTS="$(config_get "include_scripts" "true")"
INCLUDE_LAUNCHD="$(config_get "include_launchd" "true")"
INCLUDE_AGENTS="$(config_get "include_agents" "true")"
REDACT_ENV_VALUES="$(config_get "redact_env_values" "true")"

CRITICAL_FILES=()
while IFS= read -r line; do
  [ -n "$line" ] && CRITICAL_FILES+=("$line")
done < <(config_list "critical_files")
if [ "${#CRITICAL_FILES[@]}" -eq 0 ]; then
  CRITICAL_FILES=(
    "openclaw/openclaw.json"
    "workspace-config/AGENTS.md"
    "workspace-config/SOUL.md"
  )
fi

mkdir -p "$BACKUP_DIR"
MANAGED_DIRS=(openclaw agents workspace-config skills scripts launchd cron identity credentials)
for dir in "${MANAGED_DIRS[@]}"; do
  rm -rf "$BACKUP_DIR/$dir"
  mkdir -p "$BACKUP_DIR/$dir"
done

# OpenClaw config (strip placeholder secret marker)
if [ -f "$OPENCLAW_HOME/openclaw.json" ]; then
  sed 's/"__OPENCLAW_REDACTED__"/"REDACTED"/g' "$OPENCLAW_HOME/openclaw.json" > "$BACKUP_DIR/openclaw/openclaw.json"
fi

# Env files (redacted by default, configurable)
backup_env_file "$OPENCLAW_HOME/.env" "$BACKUP_DIR/openclaw/env-keys.txt"
backup_env_file "$HOME/.config/env/global.env" "$BACKUP_DIR/openclaw/global-env-keys.txt"

# Secret sync: users can add their own secret backup step here.
# Example: push to 1Password, AWS Secrets Manager, etc.
# If you use Discord/iMessage, add a custom notify hook in this section.
# See README.md for patterns.

# Agent configs (auto-discovered)
if is_true "$INCLUDE_AGENTS"; then
  for agent_dir in "$OPENCLAW_HOME"/agents/*/; do
    [ -d "$agent_dir" ] || continue
    agent_name="$(basename "$agent_dir")"
    cp "$agent_dir/agent/auth-profiles.json" "$BACKUP_DIR/agents/${agent_name}-auth-profiles.json" 2>/dev/null || true
    cp "$agent_dir/agent/auth.json" "$BACKUP_DIR/agents/${agent_name}-auth.json" 2>/dev/null || true
    cp "$agent_dir/agent/models.json" "$BACKUP_DIR/agents/${agent_name}-models.json" 2>/dev/null || true
  done
fi

# Additional OpenClaw metadata
cp "$OPENCLAW_HOME/cron/jobs.json" "$BACKUP_DIR/cron/jobs.json" 2>/dev/null || true
cp "$OPENCLAW_HOME/identity"/*.json "$BACKUP_DIR/identity/" 2>/dev/null || true
cp "$OPENCLAW_HOME/credentials"/*.json "$BACKUP_DIR/credentials/" 2>/dev/null || true

# Workspace config files
for f in AGENTS.md SOUL.md USER.md TOOLS.md IDENTITY.md HEARTBEAT.md MEMORY.md; do
  if [ -f "$OPENCLAW_HOME/workspace/$f" ]; then
    cp "$OPENCLAW_HOME/workspace/$f" "$BACKUP_DIR/workspace-config/$f"
  fi
done

# Custom skills (no node_modules)
if is_true "$INCLUDE_SKILLS"; then
  for skill_dir in "$OPENCLAW_HOME"/workspace/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$BACKUP_DIR/skills/$skill_name"
    find "$skill_dir" -maxdepth 2 \
      \( -name "*.md" -o -name "*.sh" -o -name "*.js" -o -name "*.ts" -o -name "*.json" \) \
      -not -path "*/node_modules/*" \
      -exec cp {} "$BACKUP_DIR/skills/$skill_name/" \; 2>/dev/null || true
  done
fi

# Custom scripts
if is_true "$INCLUDE_SCRIPTS"; then
  cp -R "$OPENCLAW_HOME/workspace/scripts"/* "$BACKUP_DIR/scripts/" 2>/dev/null || true
fi

# LaunchAgents
if is_true "$INCLUDE_LAUNCHD" && [ "$(uname -s)" = "Darwin" ]; then
  cp "$HOME/Library/LaunchAgents"/ai.openclaw.* "$BACKUP_DIR/launchd/" 2>/dev/null || true
  cp "$HOME/Library/LaunchAgents"/com.openclaw.* "$BACKUP_DIR/launchd/" 2>/dev/null || true
fi

# Installed packages manifest (best effort)
if command -v brew >/dev/null 2>&1; then
  brew list --cask > "$BACKUP_DIR/brew-casks.txt" 2>/dev/null || true
  brew list --formula > "$BACKUP_DIR/brew-formulas.txt" 2>/dev/null || true
fi
if command -v npm >/dev/null 2>&1; then
  npm list -g --depth=0 > "$BACKUP_DIR/npm-global.txt" 2>/dev/null || true
fi
if command -v bun >/dev/null 2>&1; then
  bun pm ls -g > "$BACKUP_DIR/bun-global.txt" 2>/dev/null || true
fi
if command -v openclaw >/dev/null 2>&1; then
  openclaw --version > "$BACKUP_DIR/openclaw-version.txt" 2>/dev/null || true
fi

cd "$BACKUP_DIR"
if [ ! -d .git ]; then
  git init -q
fi
if ! git rev-parse --verify main >/dev/null 2>&1; then
  git checkout -B main >/dev/null 2>&1 || true
else
  git checkout main >/dev/null 2>&1 || true
fi

if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_REPO" ]; then
  REMOTE_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
  else
    git remote add origin "$REMOTE_URL"
  fi
fi

git add -A
git diff --cached --quiet && exit 0
git commit -m "backup: $TIMESTAMP" --quiet

# Verification manifest (post-commit snapshot)
VERIFY_FILE="$BACKUP_DIR/backup-manifest.txt"
{
  echo "backup: $TIMESTAMP"
  echo "git_sha: $(git rev-parse HEAD)"
  echo ""
  echo "files_by_dir:"
  for dir in openclaw agents workspace-config skills scripts launchd cron identity credentials; do
    count=$(find "$BACKUP_DIR/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "  $dir: $count files"
  done
  echo ""
  echo "critical_files:"
  for f in "${CRITICAL_FILES[@]}"; do
    if [ -f "$BACKUP_DIR/$f" ]; then
      size=$(wc -c < "$BACKUP_DIR/$f" | tr -d ' ')
      echo "  OK [${size}b] $f"
    else
      echo "  MISSING $f"
    fi
  done
} > "$VERIFY_FILE"
git add "$VERIFY_FILE"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "backup-manifest: $TIMESTAMP" --quiet
fi

if [ -f "$HOME/.config/env/global.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$HOME/.config/env/global.env" 2>/dev/null || true
  set +a
fi
if [ -f "$OPENCLAW_HOME/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$OPENCLAW_HOME/.env" 2>/dev/null || true
  set +a
fi
TELEGRAM_BOT_TOKEN="${!TELEGRAM_BOT_TOKEN_ENV:-}"

# Telegram alerts require telegram_bot_token_env + telegram_chat_id in backup.json
# If telegram_chat_id is empty, failure is logged to /tmp/openclaw-backup.log but NO alert is sent (silent).
notify_telegram() {
  local msg="$1"
  [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
  [ -z "$TELEGRAM_CHAT_ID" ] && return 0
  curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d text="$msg" -d parse_mode="Markdown" >/dev/null 2>&1 || true
}

gh_auth_ready() {
  command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1
}

MISSING_CRITICAL=0
for f in "${CRITICAL_FILES[@]}"; do
  if [ ! -s "$BACKUP_DIR/$f" ]; then
    MISSING_CRITICAL=1
    break
  fi
done

if [ "$MISSING_CRITICAL" -eq 1 ]; then
  notify_telegram "⚠️ *Backup warning:* one or more critical files missing or empty. Check manifest."
fi

AUTH_REMOTE_URL=""
if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_REPO" ]; then
  if ! gh_auth_ready; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup: gh missing or not authenticated; skipping remote push (local backup only). Run 'gh auth login' after installing gh to re-enable pushes." >> /tmp/openclaw-backup.log
    exit 0
  fi
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  if [ -n "$GH_TOKEN" ]; then
    AUTH_REMOTE_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
  else
    AUTH_REMOTE_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
  fi
fi

sync_repo_with_remote() {
  [ -z "$AUTH_REMOTE_URL" ] && return 0
  # Keep local backup repo in lock-step with remote canonical history before creating a new snapshot commit.
  git fetch "$AUTH_REMOTE_URL" main --quiet >/dev/null 2>&1 || return 0
  git reset --hard FETCH_HEAD >/dev/null 2>&1 || true
}

sync_repo_with_remote

push_and_verify() {
  local push_exit local_head remote_head

  if [ -z "$AUTH_REMOTE_URL" ]; then
    return 4
  fi

  if ! git push "$AUTH_REMOTE_URL" HEAD:main --quiet >/dev/null 2>&1; then
    # Fallback: use origin remote + local credential helper (more reliable under launchd/keychain)
    if ! git push origin main --quiet >/dev/null 2>&1; then
      return 1
    fi
  fi

  # Verify: fetch remote HEAD, confirm it matches local HEAD
  local_head=$(git rev-parse HEAD)
  remote_head=$(git ls-remote "$AUTH_REMOTE_URL" HEAD 2>/dev/null | awk '{print $1}' || true)

  if [ -z "$remote_head" ]; then
    return 2
  fi

  if [ "$local_head" != "$remote_head" ]; then
    return 3
  fi

  return 0
}

if [ -z "$AUTH_REMOTE_URL" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup: github_repo/github_user not configured; skipping remote push" >> /tmp/openclaw-backup.log
  exit 0
fi

# First attempt
if push_and_verify; then
  # Success: log quietly
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup: push verified ok" >> /tmp/openclaw-backup.log
else
  FIRST_EXIT=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup: push attempt 1 failed (exit $FIRST_EXIT), retrying in 60s" >> /tmp/openclaw-backup.log
  sleep 60

  # Retry once
  if push_and_verify; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup: push verified ok (retry)" >> /tmp/openclaw-backup.log
  else
    RETRY_EXIT=$?
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup: push FAILED after retry (exit $RETRY_EXIT)" >> /tmp/openclaw-backup.log
    # If telegram_chat_id is not configured, this call is a no-op and the failure stays log-only.
    notify_telegram "⚠️ *Daily backup failed* after 1 retry.
Date: $TIMESTAMP
Exit: $RETRY_EXIT
Log: /tmp/openclaw-backup.log
Run manually: \`cd $BACKUP_DIR && git push origin main\`"
  fi
fi
