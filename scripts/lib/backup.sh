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

sentinel_backup_is_dry_run() {
  [ "${SENTINEL_DRY_RUN:-0}" = "1" ]
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

sentinel_backup_date_to_epoch() {
  local ymd="$1"
  [ -z "$ymd" ] && { printf '0\n'; return; }
  if [ "$(uname -s)" = "Darwin" ]; then
    date -j -u -f "%Y-%m-%d" "$ymd" +%s 2>/dev/null || printf '0\n'
  else
    date -u -d "$ymd 00:00:00" +%s 2>/dev/null || printf '0\n'
  fi
}

sentinel_backup_normalize_schedule() {
  local schedule="$1"
  if [[ "$schedule" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    printf '%s\n' "$schedule"
    return 0
  fi
  sentinel_backup_log "sentinel: invalid backup schedule '$schedule'; defaulting to 04:00"
  printf '04:00\n'
}

sentinel_backup_should_run() {
  local schedule="$1" last_run_iso="$2" force="$3"
  local hh mm now today_epoch yesterday_epoch last_epoch
  [ "$force" = "1" ] && return 0
  schedule="$(sentinel_backup_normalize_schedule "$schedule")"
  hh="${schedule%:*}"; mm="${schedule#*:}"
  now="$(date +%s)"
  if [ "$(uname -s)" = "Darwin" ]; then
    today_epoch="$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
    yesterday_epoch="$(date -j -v-1d -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
  else
    today_epoch="$(date -d "$(date +%Y-%m-%d) ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
    yesterday_epoch="$(date -d "yesterday ${hh}:${mm}" +%s 2>/dev/null || printf '0')"
  fi
  last_epoch="$(sentinel_backup_iso_to_epoch "$last_run_iso")"
  [ "$today_epoch" -eq 0 ] || [ "$yesterday_epoch" -eq 0 ] && { sentinel_backup_log "sentinel: backup schedule parsing failed for '$schedule'"; return 1; }
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
    git config user.name >/dev/null 2>&1 || git config user.name "OpenClaw Sentinel"
    git config user.email >/dev/null 2>&1 || git config user.email "sentinel@localhost"
  )
}

sentinel_backup_generate_manifest() {
  local backup_dir="$1" timestamp="$2" critical_list="$3"
  local content_sha="${4:-}" backup_at="${5:-}" verify_file count
  verify_file="$backup_dir/backup-manifest.txt"
  {
    echo "backup: $timestamp"
    echo "backup_at: $backup_at"
    echo "content_commit_sha: $content_sha"
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
  if sentinel_backup_is_dry_run; then
    sentinel_backup_log "sentinel: dry-run remote push for $backup_dir"
    return 0
  fi
  remote_url="https://github.com/${user}/${repo}.git"
  if ( cd "$backup_dir" || exit 1
    if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$remote_url"; else git remote add origin "$remote_url"; fi
    git push origin HEAD:main --quiet >/dev/null 2>&1
  ); then
    SENTINEL_BACKUP_LAST_PUSH_VERIFIED="true"
    SENTINEL_BACKUP_LAST_PUSH_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi
}

sentinel_backup_run_system() {
  local timestamp managed_dir critical_list content_sha backup_at
  if sentinel_backup_is_dry_run; then
    sentinel_backup_log "sentinel: dry-run system backup for $BACKUP_SYSTEM_DIR"
    SENTINEL_BACKUP_LAST_SYSTEM_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    SENTINEL_BACKUP_LAST_MANIFEST_SHA="dry-run"
    SENTINEL_BACKUP_LAST_PUSH_AT=""
    SENTINEL_BACKUP_LAST_PUSH_VERIFIED="false"
    return 0
  fi
  timestamp="$(date +%Y-%m-%d)"
  backup_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
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
  content_sha="$(git -C "$BACKUP_SYSTEM_DIR" rev-parse HEAD 2>/dev/null || true)"
  critical_list="$BACKUP_CRITICAL_FILES_NL"
  sentinel_backup_generate_manifest "$BACKUP_SYSTEM_DIR" "$timestamp" "$critical_list" "$content_sha" "$backup_at"
  ( cd "$BACKUP_SYSTEM_DIR" || exit 1; git add backup-manifest.txt; git diff --cached --quiet || git commit -m "backup-manifest: $timestamp" --quiet )
  SENTINEL_BACKUP_LAST_MANIFEST_SHA="$(git -C "$BACKUP_SYSTEM_DIR" rev-parse HEAD 2>/dev/null || true)"
  SENTINEL_BACKUP_LAST_SYSTEM_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  sentinel_backup_push_remote "$BACKUP_SYSTEM_DIR" "$BACKUP_GITHUB_USER" "$BACKUP_GITHUB_REPO"
}

sentinel_backup_manifest_timestamp_epoch() {
  local manifest="$1" backup_at backup_day
  [ -f "$manifest" ] || { printf '0\n'; return; }
  backup_at="$(awk -F': ' '/^backup_at: /{print $2; exit}' "$manifest" 2>/dev/null)"
  if [ -n "$backup_at" ]; then
    sentinel_backup_iso_to_epoch "$backup_at"
    return
  fi
  backup_day="$(awk -F': ' '/^backup: /{print $2; exit}' "$manifest" 2>/dev/null)"
  sentinel_backup_date_to_epoch "$backup_day"
}

sentinel_backup_manifest_fresh() {
  local manifest="$BACKUP_SYSTEM_DIR/backup-manifest.txt" now backup_epoch age threshold
  [ -f "$manifest" ] || return 1
  now="$(date +%s)"
  backup_epoch="$(sentinel_backup_manifest_timestamp_epoch "$manifest")"
  [ "$backup_epoch" -gt 0 ] || return 1
  age="$(( (now - backup_epoch) / 3600 ))"
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
  local force_backup="${1:-0}" last_backup ran_memory
  [ "$BACKUP_ENABLED" = "true" ] || return 0
  last_backup="$(sentinel_state_get "$STATE_FILE" '.backup.last_system_backup_at' '')"
  if sentinel_backup_should_run "$BACKUP_SCHEDULE" "$last_backup" "$force_backup"; then
    sentinel_backup_run_system
    ran_memory=0
    if sentinel_backup_memory_run "$BACKUP_MEMORY_DIR" "$OPENCLAW_HOME"; then
      SENTINEL_BACKUP_LAST_MEMORY_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      ran_memory=1
    else
      sentinel_backup_log "sentinel: memory backup failed"
    fi
    if sentinel_backup_is_dry_run; then
      sentinel_backup_log "sentinel: dry-run backup cycle complete (system and memory planned)"
      return 0
    fi
    [ "$ran_memory" -eq 1 ] || SENTINEL_BACKUP_LAST_MEMORY_AT=""
    sentinel_state_set_backup_snapshot "$STATE_FILE" "$SENTINEL_BACKUP_LAST_SYSTEM_AT" "$SENTINEL_BACKUP_LAST_MEMORY_AT" "$SENTINEL_BACKUP_LAST_PUSH_AT" "$SENTINEL_BACKUP_LAST_PUSH_VERIFIED" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
  fi
  sentinel_backup_is_dry_run && return 0
  sentinel_backup_health_check
}

sentinel_backup_ensure_recent_for_repair() {
  if sentinel_backup_manifest_fresh; then
    return 0
  fi
  if sentinel_backup_is_dry_run; then
    sentinel_backup_log "sentinel: dry-run emergency backup gate"
    return 0
  fi
  sentinel_backup_log "sentinel: running emergency backup before risky recovery tier"
  sentinel_backup_run_system || return 1
  if sentinel_backup_memory_run "$BACKUP_MEMORY_DIR" "$OPENCLAW_HOME"; then
    SENTINEL_BACKUP_LAST_MEMORY_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  else
    SENTINEL_BACKUP_LAST_MEMORY_AT=""
    sentinel_backup_log "sentinel: emergency memory backup failed"
  fi
  sentinel_state_set_backup_snapshot "$STATE_FILE" "$SENTINEL_BACKUP_LAST_SYSTEM_AT" "$SENTINEL_BACKUP_LAST_MEMORY_AT" "$SENTINEL_BACKUP_LAST_PUSH_AT" "$SENTINEL_BACKUP_LAST_PUSH_VERIFIED" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
}
