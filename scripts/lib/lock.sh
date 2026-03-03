#!/usr/bin/env bash
# shellcheck shell=bash

sentinel_lock_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sentinel_lock_to_epoch() {
  local iso="$1"
  if [ -z "$iso" ]; then
    printf '0\n'
    return 0
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || printf '0\n'
  else
    date -u -d "$iso" +%s 2>/dev/null || printf '0\n'
  fi
}

sentinel_lock_is_pid_alive() {
  local pid="$1"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

sentinel_lock_age_seconds() {
  local file="$1"
  local created now created_epoch

  created="$(jq -r '.created_at // empty' "$file" 2>/dev/null || true)"
  created_epoch="$(sentinel_lock_to_epoch "$created")"
  now="$(date +%s)"
  printf '%s\n' "$((now - created_epoch))"
}

sentinel_lock_is_stale() {
  local file="$1"
  local stale_after_seconds="$2"
  local pid age

  if [ ! -f "$file" ]; then
    return 1
  fi

  pid="$(jq -r '.pid // empty' "$file" 2>/dev/null || true)"
  age="$(sentinel_lock_age_seconds "$file")"

  if ! sentinel_lock_is_pid_alive "$pid"; then
    return 0
  fi

  if [ "$age" -gt "$stale_after_seconds" ]; then
    return 0
  fi

  return 1
}

sentinel_lock_payload_file() {
  local file="$1"
  local dir tmp now host

  dir="$(dirname "$file")"
  mkdir -p "$dir"
  now="$(sentinel_lock_now)"
  host="$(hostname)"
  tmp="$(mktemp "${dir}/.sentinel-lock.XXXXXX")" || return 1

  if ! jq -n --arg pid "$$" --arg created "$now" --arg host "$host" '
    {
      pid: ($pid | tonumber),
      created_at: $created,
      hostname: $host
    }
  ' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  printf '%s\n' "$tmp"
}

sentinel_lock_write() {
  local file="$1"
  local payload
  payload="$(sentinel_lock_payload_file "$file")" || return 1
  mv "$payload" "$file"
}

sentinel_lock_try_acquire() {
  local file="$1"
  local payload
  payload="$(sentinel_lock_payload_file "$file")" || return 1
  if ln "$payload" "$file" 2>/dev/null; then
    rm -f "$payload"
    return 0
  fi
  rm -f "$payload"
  return 1
}

sentinel_lock_acquire() {
  local file="$1"
  local stale_after_seconds="${2:-900}"

  if sentinel_lock_try_acquire "$file"; then
    return 0
  fi

  if [ -f "$file" ] && sentinel_lock_is_stale "$file" "$stale_after_seconds"; then
    rm -f "$file"
    sentinel_lock_try_acquire "$file" && return 0
  fi

  return 1
}

sentinel_lock_release() {
  local file="$1"
  local lock_pid
  if [ -f "$file" ]; then
    lock_pid="$(jq -r '.pid // empty' "$file" 2>/dev/null || true)"
    [ "$lock_pid" = "$$" ] || return 0
    rm -f "$file"
  fi
}
