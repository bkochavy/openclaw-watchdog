#!/usr/bin/env bash
# shellcheck shell=bash

sentinel_state_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

sentinel_state_default_json() {
  local now
  now="$(sentinel_state_now)"
  jq -n --arg now "$now" '{
    version: 2,
    updated_at: $now,
    health: {consecutive_failures: 0, last_healthy_at: null, current_incident_id: null},
    incident: {
      id: null, started_at: null, tier_reached: 0, repairs_attempted: 0,
      last_repair_at: null, rescue_announced: false, pre_repair_backup_sha: null
    },
    backup: {
      last_system_backup_at: null, last_memory_backup_at: null, last_push_at: null,
      last_push_verified: false, last_manifest_sha: null, alert_dedup_key: ""
    }
  }'
}

sentinel_state_write() {
  local file="$1" json="$2" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$file"
}

sentinel_state_init() {
  local file="$1"
  [ -f "$file" ] || sentinel_state_write "$file" "$(sentinel_state_default_json)"
}

sentinel_state_read() {
  local file="$1"
  sentinel_state_init "$file"
  jq -c '.' "$file" 2>/dev/null || sentinel_state_default_json
}

sentinel_state_apply() {
  local file="$1" filter="$2"
  shift 2
  local now current updated
  now="$(sentinel_state_now)"
  current="$(sentinel_state_read "$file")"
  if [ "$#" -gt 0 ]; then
    updated="$(printf '%s\n' "$current" | jq --arg now "$now" "$@" "($filter) | .updated_at = \$now")" || return 1
  else
    updated="$(printf '%s\n' "$current" | jq --arg now "$now" "($filter) | .updated_at = \$now")" || return 1
  fi
  sentinel_state_write "$file" "$updated"
}

sentinel_state_get() {
  local file="$1" filter="$2" fallback="$3" value
  value="$(sentinel_state_read "$file" | jq -r "$filter // empty" 2>/dev/null || true)"
  [ -n "$value" ] && [ "$value" != "null" ] && printf '%s\n' "$value" || printf '%s\n' "$fallback"
}

sentinel_state_mark_health_failure() { sentinel_state_apply "$1" '.health.consecutive_failures += 1'; }

sentinel_state_mark_health_success() {
  local file="$1" now
  now="$(sentinel_state_now)"
  sentinel_state_apply "$file" '
    .health.consecutive_failures = 0
    | .health.last_healthy_at = $healthy
    | .health.current_incident_id = null
    | .incident = {
        id: null, started_at: null, tier_reached: 0, repairs_attempted: 0,
        last_repair_at: null, rescue_announced: false, pre_repair_backup_sha: null
      }
  ' --arg healthy "$now"
}

sentinel_state_ensure_incident() {
  local file="$1" now incident_id
  now="$(sentinel_state_now)"
  incident_id="inc-$(date -u +"%Y%m%d-%H%M%S")"
  sentinel_state_apply "$file" '
    if (.incident.id // "") == "" then
      .incident.id = $incident
      | .incident.started_at = $started
      | .incident.tier_reached = 0
      | .incident.repairs_attempted = 0
      | .incident.last_repair_at = null
      | .incident.rescue_announced = false
      | .incident.pre_repair_backup_sha = null
      | .health.current_incident_id = $incident
    else . end
  ' --arg incident "$incident_id" --arg started "$now"
}

sentinel_state_set_tier() { sentinel_state_apply "$1" '.incident.tier_reached = ($tier | tonumber)' --arg tier "$2"; }

sentinel_state_increment_repairs() {
  local file="$1" now
  now="$(sentinel_state_now)"
  sentinel_state_apply "$file" '.incident.repairs_attempted += 1 | .incident.last_repair_at = $last' --arg last "$now"
}

sentinel_state_set_rescue_announced() { sentinel_state_apply "$1" '.incident.rescue_announced = ($v == "true")' --arg v "$2"; }

sentinel_state_set_pre_repair_backup_sha() { sentinel_state_apply "$1" '.incident.pre_repair_backup_sha = $sha' --arg sha "$2"; }

sentinel_state_set_backup_snapshot() {
  local file="$1" system_at="$2" memory_at="$3" push_at="$4" push_verified="$5" manifest_sha="$6"
  sentinel_state_apply "$file" '
    .backup.last_system_backup_at = $system_at
    | .backup.last_memory_backup_at = $memory_at
    | .backup.last_push_at = $push_at
    | .backup.last_push_verified = ($push_verified == "true")
    | .backup.last_manifest_sha = $manifest_sha
  ' --arg system_at "$system_at" --arg memory_at "$memory_at" --arg push_at "$push_at" --arg push_verified "$push_verified" --arg manifest_sha "$manifest_sha"
}

sentinel_state_set_backup_alert_key() { sentinel_state_apply "$1" '.backup.alert_dedup_key = $key' --arg key "$2"; }

sentinel_state_reset_incident() {
  local file="$1"
  sentinel_state_apply "$file" '
    .health.consecutive_failures = 0
    | .health.current_incident_id = null
    | .incident = {
        id: null, started_at: null, tier_reached: 0, repairs_attempted: 0,
        last_repair_at: null, rescue_announced: false, pre_repair_backup_sha: null
      }
  '
}
