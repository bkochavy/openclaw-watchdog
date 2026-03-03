#!/usr/bin/env bash
# shellcheck shell=bash

SENTINEL_BACKUP_LAST_SYSTEM_AT=""
SENTINEL_BACKUP_LAST_MEMORY_AT=""
SENTINEL_BACKUP_LAST_PUSH_AT=""
SENTINEL_BACKUP_LAST_PUSH_VERIFIED="false"
SENTINEL_BACKUP_LAST_MANIFEST_SHA=""

sentinel_backup_log() {
  local msg="$1"
  if declare -F sentinel_log >/dev/null 2>&1; then
    sentinel_log "$msg"
  fi
}

sentinel_backup_hash() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum | awk '{print $1}'
  else
    printf '%s' "$input" | sha1sum | awk '{print $1}'
  fi
}

sentinel_backup_iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && { printf '0\n'; return; }
  if [ "$(uname -s)" = "Darwin" ]; then
    date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || printf '0\n'
  else
    date -u -d "$iso" +%s 2>/dev/null || printf '0\n'
  fi
}

sentinel_backup_should_run() {
  local schedule="$1" last_run_iso="$2" force="$3"
  local hh mm now today_epoch yesterday_epoch last_epoch
  [ "$force" = "1" ] && return 0
  hh="${schedule%:*}"; mm="${schedule#*:}"
  hh="${hh:-04}"; mm="${mm:-00}"
  now="$(date +%s)"
  if [ "$(uname -s)" = "Darwin" ]; then
    today_epoch="$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
    yesterday_epoch="$(date -j -v-1d -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
  else
    today_epoch="$(date -d "$(date +%Y-%m-%d) ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
    yesterday_epoch="$(date -d "yesterday ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
  fi
  last_epoch="$(sentinel_backup_iso_to_epoch "$last_run_iso")"
  [ "$today_epoch" -eq 0 ] && return 0
  if [ "$now" -ge "$today_epoch" ]; then [ "$last_epoch" -lt "$today_epoch" ]; else [ "$last_epoch" -lt "$yesterday_epoch" ]; fi
}

sentinel_backup_copy_env() {
  local src="$1" dst="$2" redact="$3"
  [ -f "$src" ] || return 0
  if [ "$redact" = "true" ]; then sed 's/=.*/=REDACTED/' "$src" > "$dst"; else cp "$src" "$dst"; fi
}

sentinel_backup_git_prepare() {
  local repo="$1"
  ( cd "$repo" || exit 1
    [ -d .git ] || git init -q
    if ! git rev-parse --verify main >/dev/null 2>&1; then git checkout -B main >/dev/null 2>&1 || true; else git checkout main >/dev/null 2>&1 || true; fi
  )
}

sentinel_backup_generate_manifest() {
  local backup_dir="$1" timestamp="$2" critical_list="$3" verify_file
  verify_file="$backup_dir/backup-manifest.txt"
  {
    echo "backup: $timestamp"
    echo "git_sha: $(git -C "$backup_dir" rev-parse HEAD 2>/dev/null || true)"
    echo ""
    echo "files_by_dir:"
    for dir in openclaw agents workspace-config skills scripts launchd cron identity credentials; do
      count=$(find "$backup_dir/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "  $dir: $count files"
    done
    echo ""
    echo "critical_files:"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -f "$backup_dir/$f" ]; then echo "  OK [$(( $(wc -c < "$backup_dir/$f") ))b] $f"; else echo "  MISSING $f"; fi
    done <<< "$critical_list"
  } > "$verify_file"
}

sentinel_backup_push_remote() {
  local backup_dir="$1" user="$2" repo="$3" remote_url
  SENTINEL_BACKUP_LAST_PUSH_VERIFIED="false"
  SENTINEL_BACKUP_LAST_PUSH_AT=""
  [ -n "$user" ] && [ -n "$repo" ] || return 0
  remote_url="https://github.com/${user}/${repo}.git"
  ( cd "$backup_dir" || exit 1
    if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$remote_url"; else git remote add origin "$remote_url"; fi
    if git push origin HEAD:main --quiet >/dev/null 2>&1; then
      SENTINEL_BACKUP_LAST_PUSH_VERIFIED="true"
      SENTINEL_BACKUP_LAST_PUSH_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    fi
  )
}

sentinel_backup_run_system() {
  local timestamp managed_dir critical_list
  timestamp="$(date +%Y-%m-%d)"
  mkdir -p "$BACKUP_SYSTEM_DIR"
  managed_dir="openclaw agents workspace-config skills scripts launchd cron identity credentials"
  for dir in $managed_dir; do rm -rf "$BACKUP_SYSTEM_DIR/$dir"; mkdir -p "$BACKUP_SYSTEM_DIR/$dir"; done

  [ -f "$OPENCLAW_HOME/openclaw.json" ] && sed 's/"__OPENCLAW_REDACTED__"/"REDACTED"/g' "$OPENCLAW_HOME/openclaw.json" > "$BACKUP_SYSTEM_DIR/openclaw/openclaw.json"
  sentinel_backup_copy_env "$OPENCLAW_HOME/.env" "$BACKUP_SYSTEM_DIR/openclaw/env-keys.txt" "$BACKUP_REDACT_ENV_VALUES"
  sentinel_backup_copy_env "$HOME/.config/env/global.env" "$BACKUP_SYSTEM_DIR/openclaw/global-env-keys.txt" "$BACKUP_REDACT_ENV_VALUES"

  if [ "$BACKUP_INCLUDE_AGENTS" = "true" ]; then
    for agent_dir in "$OPENCLAW_HOME"/agents/*/; do
      [ -d "$agent_dir" ] || continue
      agent_name="$(basename "$agent_dir")"
      cp "$agent_dir/agent/auth-profiles.json" "$BACKUP_SYSTEM_DIR/agents/${agent_name}-auth-profiles.json" 2>/dev/null || true
      cp "$agent_dir/agent/auth.json" "$BACKUP_SYSTEM_DIR/agents/${agent_name}-auth.json" 2>/dev/null || true
      cp "$agent_dir/agent/models.json" "$BACKUP_SYSTEM_DIR/agents/${agent_name}-models.json" 2>/dev/null || true
    done
  fi

  cp "$OPENCLAW_HOME/cron/jobs.json" "$BACKUP_SYSTEM_DIR/cron/jobs.json" 2>/dev/null || true
  cp "$OPENCLAW_HOME/identity"/*.json "$BACKUP_SYSTEM_DIR/identity/" 2>/dev/null || true
  cp "$OPENCLAW_HOME/credentials"/*.json "$BACKUP_SYSTEM_DIR/credentials/" 2>/dev/null || true
  for f in AGENTS.md SOUL.md USER.md TOOLS.md IDENTITY.md HEARTBEAT.md MEMORY.md; do
    [ -f "$OPENCLAW_HOME/workspace/$f" ] && cp "$OPENCLAW_HOME/workspace/$f" "$BACKUP_SYSTEM_DIR/workspace-config/$f"
  done

  [ "$BACKUP_INCLUDE_SCRIPTS" = "true" ] && cp -R "$OPENCLAW_HOME/workspace/scripts"/* "$BACKUP_SYSTEM_DIR/scripts/" 2>/dev/null || true
  if [ "$BACKUP_INCLUDE_SKILLS" = "true" ]; then
    for skill_dir in "$OPENCLAW_HOME"/workspace/skills/*/; do [ -d "$skill_dir" ] || continue; skill_name="$(basename "$skill_dir")"; mkdir -p "$BACKUP_SYSTEM_DIR/skills/$skill_name"; find "$skill_dir" -maxdepth 2 \( -name '*.md' -o -name '*.sh' -o -name '*.js' -o -name '*.ts' -o -name '*.json' \) -not -path '*/node_modules/*' -exec cp {} "$BACKUP_SYSTEM_DIR/skills/$skill_name/" \; 2>/dev/null || true; done
  fi
  if [ "$BACKUP_INCLUDE_LAUNCHD" = "true" ] && [ "$(uname -s)" = "Darwin" ]; then cp "$HOME/Library/LaunchAgents"/ai.openclaw.* "$BACKUP_SYSTEM_DIR/launchd/" 2>/dev/null || true; fi

  sentinel_backup_git_prepare "$BACKUP_SYSTEM_DIR"
  ( cd "$BACKUP_SYSTEM_DIR" || exit 1; git add -A; git diff --cached --quiet || git commit -m "backup: $timestamp" --quiet )
  critical_list="$BACKUP_CRITICAL_FILES_NL"
  sentinel_backup_generate_manifest "$BACKUP_SYSTEM_DIR" "$timestamp" "$critical_list"
  ( cd "$BACKUP_SYSTEM_DIR" || exit 1; git add backup-manifest.txt; git diff --cached --quiet || git commit -m "backup-manifest: $timestamp" --quiet )
  SENTINEL_BACKUP_LAST_MANIFEST_SHA="$(git -C "$BACKUP_SYSTEM_DIR" rev-parse HEAD 2>/dev/null || true)"
  SENTINEL_BACKUP_LAST_SYSTEM_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  sentinel_backup_push_remote "$BACKUP_SYSTEM_DIR" "$BACKUP_GITHUB_USER" "$BACKUP_GITHUB_REPO"
}

sentinel_backup_manifest_fresh() {
  local manifest="$BACKUP_SYSTEM_DIR/backup-manifest.txt" now mtime age threshold
  [ -f "$manifest" ] || return 1
  now="$(date +%s)"
  if [ "$(uname -s)" = "Darwin" ]; then mtime="$(stat -f %m "$manifest" 2>/dev/null || printf '0')"; else mtime="$(stat -c %Y "$manifest" 2>/dev/null || printf '0')"; fi
  age="$(( (now - mtime) / 3600 ))"
  threshold="${BACKUP_MAX_AGE_HOURS:-30}"
  [ "$age" -le "$threshold" ]
}

sentinel_backup_health_check() {
  local reasons="" key last_key
  sentinel_backup_manifest_fresh || reasons="manifest stale or missing"
  if [ -n "$reasons" ]; then
    key="$(sentinel_backup_hash "$reasons")"
    last_key="$(sentinel_state_get "$STATE_FILE" '.backup.alert_dedup_key' '')"
    if [ "$key" != "$last_key" ]; then
      sentinel_notify_send "⚠️ OpenClaw sentinel backup health check failed: ${reasons}"
      sentinel_state_set_backup_alert_key "$STATE_FILE" "$key"
    fi
  else
    sentinel_state_set_backup_alert_key "$STATE_FILE" ""
  fi
}

sentinel_backup_run_cycle() {
  local force_backup="${1:-0}" last_backup
  [ "$BACKUP_ENABLED" = "true" ] || return 0
  last_backup="$(sentinel_state_get "$STATE_FILE" '.backup.last_system_backup_at' '')"
  if sentinel_backup_should_run "$BACKUP_SCHEDULE" "$last_backup" "$force_backup"; then
    sentinel_backup_run_system
    sentinel_backup_memory_run "$BACKUP_MEMORY_DIR" "$OPENCLAW_HOME"
    SENTINEL_BACKUP_LAST_MEMORY_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    sentinel_state_set_backup_snapshot "$STATE_FILE" "$SENTINEL_BACKUP_LAST_SYSTEM_AT" "$SENTINEL_BACKUP_LAST_MEMORY_AT" "$SENTINEL_BACKUP_LAST_PUSH_AT" "$SENTINEL_BACKUP_LAST_PUSH_VERIFIED" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
  fi
  sentinel_backup_health_check
}

sentinel_backup_ensure_recent_for_repair() {
  if sentinel_backup_manifest_fresh; then
    return 0
  fi
  sentinel_backup_log "sentinel: running emergency backup before risky recovery tier"
  sentinel_backup_run_system
  sentinel_backup_memory_run "$BACKUP_MEMORY_DIR" "$OPENCLAW_HOME"
  SENTINEL_BACKUP_LAST_MEMORY_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  sentinel_state_set_backup_snapshot "$STATE_FILE" "$SENTINEL_BACKUP_LAST_SYSTEM_AT" "$SENTINEL_BACKUP_LAST_MEMORY_AT" "$SENTINEL_BACKUP_LAST_PUSH_AT" "$SENTINEL_BACKUP_LAST_PUSH_VERIFIED" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
}
