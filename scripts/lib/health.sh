#!/usr/bin/env bash
# shellcheck shell=bash

SENTINEL_HEALTH_LAST_SOURCE=""
SENTINEL_HEALTH_LAST_BODY=""

sentinel_health_probe_url() {
  local health_url="$1"
  local timeout_seconds="${2:-5}"
  local body

  body="$(curl -fsS --max-time "$timeout_seconds" "$health_url" 2>/dev/null)" || return 1
  if printf '%s\n' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    SENTINEL_HEALTH_LAST_SOURCE="healthz"
    SENTINEL_HEALTH_LAST_BODY="$body"
    return 0
  fi

  return 1
}

sentinel_health_probe_fallback() {
  local openclaw_bin="${OPENCLAW_BIN:-openclaw}"
  local body

  if ! command -v "$openclaw_bin" >/dev/null 2>&1; then
    return 1
  fi

  body="$($openclaw_bin gateway status --json 2>/dev/null)" || return 1
  if printf '%s\n' "$body" | jq -e '(.ok == true) or (.healthy == true)' >/dev/null 2>&1; then
    SENTINEL_HEALTH_LAST_SOURCE="gateway-status"
    SENTINEL_HEALTH_LAST_BODY="$body"
    return 0
  fi

  return 1
}

sentinel_health_probe() {
  local health_url="$1"
  local timeout_seconds="${2:-5}"

  SENTINEL_HEALTH_LAST_SOURCE=""
  SENTINEL_HEALTH_LAST_BODY=""

  if sentinel_health_probe_url "$health_url" "$timeout_seconds"; then
    return 0
  fi

  sentinel_health_probe_fallback
}

sentinel_health_wait_for_ok() {
  local health_url="$1"
  local checks="${2:-1}"
  local sleep_seconds="${3:-10}"
  local i

  i=1
  while [ "$i" -le "$checks" ]; do
    if ! sentinel_health_probe "$health_url" 5; then
      return 1
    fi

    if [ "$i" -lt "$checks" ]; then
      sleep "$sleep_seconds"
    fi
    i=$((i + 1))
  done

  return 0
}
