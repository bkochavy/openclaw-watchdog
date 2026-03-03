#!/usr/bin/env bash
# shellcheck shell=bash

SENTINEL_MEMORY_BACKUP_SHA=""

sentinel_backup_memory_log() {
  local msg="$1"
  if declare -F sentinel_log >/dev/null 2>&1; then
    sentinel_log "$msg"
  fi
}

sentinel_backup_memory_is_dry_run() {
  [ "${SENTINEL_DRY_RUN:-0}" = "1" ]
}

sentinel_backup_memory_sync_dir() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src" "$dst/" >/dev/null 2>&1 || true
  else
    rm -rf "$dst"/*
    cp -R "$src"/* "$dst/" 2>/dev/null || true
  fi
}

sentinel_backup_memory_git_prepare() {
  local repo="$1"
  ( cd "$repo" || exit 1
    [ -d .git ] || git init -q
    if ! git rev-parse --verify main >/dev/null 2>&1; then
      git checkout -B main >/dev/null 2>&1 || true
    else
      git checkout main >/dev/null 2>&1 || true
    fi
    git config user.name >/dev/null 2>&1 || git config user.name "OpenClaw Sentinel"
    git config user.email >/dev/null 2>&1 || git config user.email "sentinel@localhost"
  )
}

sentinel_backup_memory_commit() {
  local repo="$1" message="$2"
  ( cd "$repo" || exit 1
    git add -A
    git diff --cached --quiet && exit 0
    git commit -m "$message" --quiet
    git rev-parse HEAD
  )
}

sentinel_backup_memory_run() {
  local backup_dir="$1"
  local openclaw_home="${2:-${OPENCLAW_HOME:-$HOME/.openclaw}}"
  local timestamp

  if sentinel_backup_memory_is_dry_run; then
    sentinel_backup_memory_log "sentinel: dry-run memory backup for $backup_dir"
    SENTINEL_MEMORY_BACKUP_SHA="dry-run"
    return 0
  fi

  timestamp="$(date +%Y-%m-%d)"
  mkdir -p "$backup_dir/memory" "$backup_dir/life" "$backup_dir/sessions"

  cp "$openclaw_home/workspace/MEMORY.md" "$backup_dir/" 2>/dev/null || true
  [ -d "$openclaw_home/workspace/memory" ] && sentinel_backup_memory_sync_dir "$openclaw_home/workspace/memory/" "$backup_dir/memory"
  [ -d "$openclaw_home/workspace/life" ] && sentinel_backup_memory_sync_dir "$openclaw_home/workspace/life/" "$backup_dir/life"

  for agent_dir in "$openclaw_home"/agents/*/; do
    [ -d "$agent_dir" ] || continue
    agent_name="$(basename "$agent_dir")"
    mkdir -p "$backup_dir/sessions/$agent_name"
    [ -d "$agent_dir/qmd/sessions" ] && sentinel_backup_memory_sync_dir "$agent_dir/qmd/sessions/" "$backup_dir/sessions/$agent_name"
  done

  cp "$HOME/.cache/qmd/index.sqlite" "$backup_dir/qmd-index.sqlite" 2>/dev/null || true

  sentinel_backup_memory_git_prepare "$backup_dir"
  if ! SENTINEL_MEMORY_BACKUP_SHA="$(sentinel_backup_memory_commit "$backup_dir" "memory: $timestamp" 2>/dev/null)"; then
    sentinel_backup_memory_log "sentinel: memory backup commit failed"
    return 1
  fi
  return 0
}
