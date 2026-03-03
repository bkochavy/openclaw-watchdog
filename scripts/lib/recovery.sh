#!/usr/bin/env bash
# shellcheck shell=bash

sentinel_recovery_log() { declare -F sentinel_log >/dev/null 2>&1 && sentinel_log "$1"; }

sentinel_recovery_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && { printf '0\n'; return; }
  if [ "$(uname -s)" = "Darwin" ]; then date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || printf '0\n'; else date -u -d "$iso" +%s 2>/dev/null || printf '0\n'; fi
}

sentinel_recovery_exec() {
  if [ "${SENTINEL_DRY_RUN:-0}" = "1" ]; then sentinel_recovery_log "dry-run: $*"; return 0; fi
  "$@"
}

sentinel_recovery_resolve_agent() {
  if [ -n "$RECOVERY_CODEX_BIN" ] && [ -x "$RECOVERY_CODEX_BIN" ]; then printf 'codex:%s\n' "$RECOVERY_CODEX_BIN"; return 0; fi
  if command -v codex >/dev/null 2>&1; then printf 'codex:%s\n' "$(command -v codex)"; return 0; fi
  if [ -n "$RECOVERY_CLAUDE_BIN" ] && [ -x "$RECOVERY_CLAUDE_BIN" ]; then printf 'claude:%s\n' "$RECOVERY_CLAUDE_BIN"; return 0; fi
  if command -v claude >/dev/null 2>&1; then printf 'claude:%s\n' "$(command -v claude)"; return 0; fi
  printf 'none:\n'
  return 1
}

sentinel_recovery_run_agent() {
  local timeout_seconds="$1" prompt="$2" agent kind bin
  agent="$(sentinel_recovery_resolve_agent || true)"; kind="${agent%%:*}"; bin="${agent#*:}"
  [ "$kind" = "none" ] && { sentinel_notify_send "🚨 Sentinel could not find Codex or Claude CLI."; return 127; }
  if [ "$kind" = "codex" ]; then
    sentinel_recovery_exec "$bin" --dangerously-bypass-approvals-and-sandbox --model "$RECOVERY_CODEX_MODEL" "$prompt"
  else
    sentinel_recovery_exec "$bin" --dangerously-skip-permissions "$prompt"
  fi
}

sentinel_recovery_wait_check() {
  local seconds="$1"
  [ "$seconds" -gt 0 ] && sleep "$seconds"
  sentinel_health_probe "$HEALTH_URL" 5
}

sentinel_recovery_try_deterministic() {
  local tier="$1" cmd_desc="$2"
  shift 2
  sentinel_state_set_tier "$STATE_FILE" "$tier"
  sentinel_recovery_log "sentinel: tier ${tier} - ${cmd_desc}"
  sentinel_recovery_exec "$@" >/dev/null 2>&1 || true
  sentinel_recovery_wait_check 45
}

sentinel_recovery_try_rollback() {
  local backup_cfg="$BACKUP_SYSTEM_DIR/openclaw/openclaw.json"
  sentinel_state_set_tier "$STATE_FILE" 3
  sentinel_backup_ensure_recent_for_repair || return 1
  [ -n "$SENTINEL_BACKUP_LAST_MANIFEST_SHA" ] && sentinel_state_set_pre_repair_backup_sha "$STATE_FILE" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
  [ -f "$backup_cfg" ] || return 1
  mkdir -p "$OPENCLAW_HOME"
  cp "$backup_cfg" "$OPENCLAW_HOME/openclaw.json"
  sentinel_recovery_exec openclaw gateway restart >/dev/null 2>&1 || true
  sentinel_recovery_wait_check 45
}

sentinel_recovery_try_agent() {
  local prompt log_file stamp result
  sentinel_state_set_tier "$STATE_FILE" 4
  sentinel_backup_ensure_recent_for_repair || true
  [ -n "$SENTINEL_BACKUP_LAST_MANIFEST_SHA" ] && sentinel_state_set_pre_repair_backup_sha "$STATE_FILE" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"; log_file="$LOG_DIR/sentinel-agent-$stamp.log"
  prompt="OpenClaw gateway is unhealthy. Diagnose and repair safely. Validate with curl ${HEALTH_URL} showing {\"ok\":true}. Do not modify memory or identity docs."
  result="$(sentinel_recovery_run_agent "$RECOVERY_CODEX_TIMEOUT" "$prompt" 2>&1)" || true
  printf '%s\n' "$result" > "$log_file"
  sentinel_state_increment_repairs "$STATE_FILE"
  sentinel_recovery_wait_check 10
}

sentinel_recovery_rescue_mode() {
  local announced cmd prompt stamp log_file output
  announced="$(sentinel_state_get "$STATE_FILE" '.incident.rescue_announced' 'false')"
  if [ "$announced" != "true" ]; then
    sentinel_tg_prime_offset "$SENTINEL_NOTIFY_TG_TOKEN" "$RECOVERY_OFFSET_FILE"
    sentinel_notify_send "🚨 Auto-repair limit reached. Rescue mode active. Send ${RECOVERY_RESCUE_PREFIX} <command>."
    sentinel_state_set_rescue_announced "$STATE_FILE" true
    return 0
  fi

  cmd="$(sentinel_tg_fetch_prefixed_command "$SENTINEL_NOTIFY_TG_TOKEN" "$SENTINEL_NOTIFY_TG_CHAT" "$RECOVERY_RESCUE_PREFIX" "$RECOVERY_OFFSET_FILE" || true)"
  [ -z "$cmd" ] && return 0
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"; log_file="$LOG_DIR/sentinel-rescue-$stamp.log"
  prompt="Operator command: ${cmd}. Execute safely and attempt recovery. Validate health via ${HEALTH_URL}."
  output="$(sentinel_recovery_run_agent "$RECOVERY_RESCUE_TIMEOUT" "$prompt" 2>&1)" || true
  printf '%s\n' "$output" > "$log_file"
  sentinel_state_increment_repairs "$STATE_FILE"
  if sentinel_recovery_wait_check 8; then sentinel_notify_send "✅ Rescue command recovered gateway."; else sentinel_notify_send "❌ Rescue command did not recover gateway yet."; fi
}

sentinel_recovery_run() {
  local failures tier repairs last_repair now elapsed
  failures="$(sentinel_state_get "$STATE_FILE" '.health.consecutive_failures' '0')"
  [ "$failures" -lt "$RECOVERY_MAX_FAILURES" ] && return 0

  sentinel_state_ensure_incident "$STATE_FILE"
  tier="$(sentinel_state_get "$STATE_FILE" '.incident.tier_reached' '0')"
  repairs="$(sentinel_state_get "$STATE_FILE" '.incident.repairs_attempted' '0')"
  last_repair="$(sentinel_state_get "$STATE_FILE" '.incident.last_repair_at' '')"
  now="$(date +%s)"; elapsed="$((now - $(sentinel_recovery_to_epoch "$last_repair")))"

  if [ "$repairs" -ge "$RECOVERY_MAX_REPAIRS" ]; then sentinel_state_set_tier "$STATE_FILE" 5; sentinel_recovery_rescue_mode; return 0; fi
  if [ "$tier" -ge 4 ] && [ "$elapsed" -lt "$RECOVERY_COOLDOWN_SECONDS" ]; then sentinel_recovery_log "sentinel: recovery cooldown active"; return 0; fi

  if [ "$tier" -lt 1 ] && [ "$RECOVERY_RESTART_ENABLED" = "true" ] && sentinel_recovery_try_deterministic 1 "gateway restart" openclaw gateway restart; then sentinel_state_mark_health_success "$STATE_FILE"; sentinel_notify_send "🟢 Sentinel recovered gateway at tier 1."; return 0; fi
  if [ "$tier" -lt 2 ] && [ "$RECOVERY_DOCTOR_ENABLED" = "true" ] && sentinel_recovery_try_deterministic 2 "doctor fix" openclaw doctor --fix --non-interactive; then sentinel_state_mark_health_success "$STATE_FILE"; sentinel_notify_send "🟢 Sentinel recovered gateway at tier 2."; return 0; fi
  if [ "$tier" -lt 3 ] && [ "$RECOVERY_ROLLBACK_ENABLED" = "true" ] && sentinel_recovery_try_rollback; then sentinel_state_mark_health_success "$STATE_FILE"; sentinel_notify_send "🟢 Sentinel recovered gateway at tier 3 rollback."; return 0; fi

  sentinel_recovery_try_agent || true
  if sentinel_health_probe "$HEALTH_URL" 5; then
    sentinel_state_mark_health_success "$STATE_FILE"
    sentinel_notify_send "🟢 Sentinel recovered gateway with coding agent repair."
  else
    sentinel_recovery_rescue_mode
  fi
}
