# PRD: OpenClaw Sentinel — Unified Watchdog & Backup System

**Version:** 1.0  
**Date:** 2026-03-02  
**Author:** Ava (operator) + Ben (owner)  
**Repo:** `bkochavy/openclaw-watchdog` (evolves into `openclaw-sentinel`)

---

## 1. Problem Statement

OpenClaw currently ships two separate tools for system resilience:

1. **openclaw-watchdog** — monitors gateway health, auto-repairs via coding agents, has Telegram rescue mode
2. **openclaw-backup** — daily system config + memory backups, GitHub push, health-check alerts

These are independently scheduled (separate launchd/systemd timers), have overlapping config surfaces, duplicate Telegram notification code, and don't talk to each other. The watchdog doesn't know if a backup exists before attempting dangerous repairs. The backup tool doesn't know if the gateway is down. Neither leverages OpenClaw's built-in health endpoints properly.

Guardian (LeoYeAI/openclaw-guardian) showed us one good idea we're missing: **deterministic repair before LLM escalation** (`openclaw gateway restart` → `doctor --fix` → *then* coding agent). Our watchdog skips straight to LLM.

## 2. Vision

**One elegant system** — `openclaw-sentinel` — that handles both gateway resilience and backup management as a unified, scheduler-driven service. It should feel like a single well-designed tool, not two bolted-together scripts.

### Design Principles

- **Deterministic first, LLM last.** Never invoke a coding agent before exhausting `gateway restart`, `doctor --fix`, and config rollback.
- **Backup-aware recovery.** Before risky repairs, verify a recent backup exists. If not, snapshot first.
- **Strict health semantics.** Use OpenClaw's actual `/healthz` endpoint and validate JSON response, not just "did curl succeed."
- **Unified config.** One JSON file, one service, one timer schedule.
- **Elegant state management.** JSON state with atomic writes, stale-lock detection, structured incident history.
- **Minimal dependencies.** Bash + curl + jq + git. Python3 optional (fallback for timeout). No Node.js runtime dependency for the sentinel itself.

## 3. Architecture

### 3.1 Execution Model

Single oneshot script invoked by OS scheduler (launchd timer on macOS, systemd timer on Linux). Each invocation runs a decision tree:

```
┌─────────────────────────────────────┐
│         Sentinel Invocation         │
├─────────────────────────────────────┤
│ 1. Acquire lock (JSON + PID + port) │
│ 2. Load config + state              │
│ 3. Health check (/healthz)          │
│    ├── HEALTHY → run backup cycle   │
│    └── UNHEALTHY → recovery flow    │
│ 4. Release lock                     │
└─────────────────────────────────────┘
```

### 3.2 Recovery Flow (Tiered)

When gateway is unhealthy, follow strict escalation:

```
Tier 0: Transient — wait for next check (failure count < threshold)
Tier 1: Deterministic restart
        → openclaw gateway restart
        → wait 45s, recheck /healthz
Tier 2: Doctor fix
        → openclaw doctor --fix --non-interactive
        → wait 45s, recheck /healthz
Tier 3: Config rollback (if backup available)
        → restore last known-good openclaw.json from backup
        → openclaw gateway restart
        → recheck /healthz
Tier 4: Coding agent repair (Codex/Claude)
        → existing repair prompt logic (improved)
        → Telegram notifications
Tier 5: Rescue mode
        → existing Telegram command routing
        → operator sends commands via chat prefix
```

Each tier only fires if the previous tier failed. Cooldowns apply between tier 4 attempts.

### 3.3 Backup Subsystem (Integrated)

The backup cycle runs on healthy checks (or on-demand via flag):

```
Backup Decision Tree:
├── Is backup due? (schedule check: daily at configured hour, or forced)
│   ├── NO  → skip
│   └── YES →
│       ├── System backup (config, agents, skills, launchd, scripts, env keys)
│       ├── Memory backup (MEMORY.md, memory/*, life/*, session summaries)
│       ├── Git commit (local)
│       ├── Git push (if GitHub configured)
│       ├── Generate manifest + verify critical files
│       └── Backup health assessment (age, completeness)
└── Backup health check (regardless of schedule)
    ├── Manifest exists and fresh? → OK
    └── Stale or missing? → Telegram alert (deduplicated)
```

### 3.4 Pre-Repair Backup Gate

Before any tier 3+ recovery action:

1. Check if a recent backup exists (manifest age < 24h)
2. If no backup, run emergency snapshot first
3. Log pre-repair backup SHA for rollback reference
4. Proceed with repair

This ensures we never attempt risky operations without a safety net.

## 4. Unified Config Schema

Single file: `~/.openclaw/sentinel.json`

```json
{
  "health_url": "http://127.0.0.1:18789/healthz",
  "check_interval_seconds": 300,

  "recovery": {
    "max_failures_before_action": 2,
    "cooldown_seconds": 1800,
    "max_repairs_per_incident": 3,
    "deterministic_restart_enabled": true,
    "deterministic_doctor_enabled": true,
    "config_rollback_enabled": true,
    "codex_timeout_seconds": 180,
    "rescue_timeout_seconds": 420,
    "rescue_command_prefix": "/codex",
    "codex_model": "gpt-5.3-codex",
    "codex_bin": "",
    "claude_bin": ""
  },

  "backup": {
    "enabled": true,
    "schedule": "04:00",
    "system_backup_dir": "~/backups/openclaw-system",
    "memory_backup_dir": "~/backups/openclaw-memory",
    "github_repo": "",
    "github_user": "",
    "include_skills": true,
    "include_scripts": true,
    "include_launchd": true,
    "include_agents": true,
    "redact_env_values": true,
    "max_backup_age_hours": 30,
    "critical_files": [
      "openclaw/openclaw.json",
      "workspace-config/AGENTS.md",
      "workspace-config/SOUL.md"
    ]
  },

  "notifications": {
    "telegram_bot_token_env": "TELEGRAM_BOT_TOKEN_AVA",
    "telegram_chat_id": "",
    "discord_webhook_url": "",
    "notify_on_recovery": true,
    "notify_on_backup_failure": true,
    "notify_on_backup_success": false
  },

  "state_file": "~/.openclaw/state/sentinel-state.json",
  "lock_file": "~/.openclaw/state/sentinel.lock",
  "recovery_log": "~/.openclaw/workspace/memory/recovery-log.md",
  "log_dir": "~/.openclaw/logs"
}
```

### Migration

- Reads legacy `watchdog.json` and `backup.json` if `sentinel.json` doesn't exist
- One-time auto-migration on first run with `--migrate` flag
- Install script handles migration during upgrade

## 5. State Management

### 5.1 State File Format

JSON with atomic write (temp file + rename):

```json
{
  "version": 2,
  "updated_at": "2026-03-02T21:00:00Z",
  "health": {
    "consecutive_failures": 0,
    "last_healthy_at": "2026-03-02T20:55:00Z",
    "current_incident_id": null
  },
  "incident": {
    "id": "inc-20260302-2100",
    "started_at": "2026-03-02T21:00:00Z",
    "tier_reached": 2,
    "repairs_attempted": 1,
    "last_repair_at": "2026-03-02T21:05:00Z",
    "rescue_announced": false,
    "pre_repair_backup_sha": "abc1234"
  },
  "backup": {
    "last_system_backup_at": "2026-03-02T04:00:00Z",
    "last_memory_backup_at": "2026-03-02T04:00:05Z",
    "last_push_at": "2026-03-02T04:01:00Z",
    "last_push_verified": true,
    "last_manifest_sha": "def5678",
    "alert_dedup_key": ""
  }
}
```

### 5.2 Lock File Format

JSON with PID, timestamp, and optional port probe:

```json
{
  "pid": 12345,
  "created_at": "2026-03-02T21:00:00Z",
  "hostname": "novas-mac-mini"
}
```

Stale lock detection: check PID alive + age > 15 minutes.

## 6. Health Check Improvements

### Current (broken)
```bash
curl -s --max-time 5 "$HEALTH_URL" >/dev/null 2>&1
```
- Treats any HTTP response as healthy
- Default URL is root path, not `/healthz`
- No JSON body validation

### New (strict)
```bash
probe_health() {
  local body
  body=$(curl -fsS --max-time 5 "$HEALTH_URL" 2>/dev/null) || return 1
  echo "$body" | jq -e '.ok == true' >/dev/null 2>&1
}
```
- Uses `-f` (fail on HTTP errors)
- Validates `ok: true` in JSON response
- Default URL includes `/healthz`
- Falls back to `openclaw gateway status --json` if endpoint unreachable

## 7. File Structure

```
openclaw-sentinel/
├── scripts/
│   ├── sentinel.sh              # Main unified script
│   ├── lib/
│   │   ├── config.sh            # Config loading + migration
│   │   ├── health.sh            # Health probe functions
│   │   ├── recovery.sh          # Tiered recovery logic
│   │   ├── backup.sh            # Backup subsystem
│   │   ├── backup-memory.sh     # Memory-specific backup
│   │   ├── state.sh             # JSON state management
│   │   ├── lock.sh              # Lock acquisition/release
│   │   ├── notify.sh            # Telegram + Discord notifications
│   │   └── tg-helper.sh         # Runtime TG helper for coding agents
├── templates/
│   ├── launchd/
│   │   └── ai.openclaw.sentinel.plist.template
│   └── systemd/
│       ├── openclaw-sentinel.service
│       └── openclaw-sentinel.timer
├── tests/
│   ├── test_health.sh
│   ├── test_recovery.sh
│   ├── test_backup.sh
│   ├── test_state.sh
│   └── test_integration.sh
├── install.sh                    # Unified installer (replaces both)
├── uninstall.sh
├── sentinel.example.json
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## 8. Install / Upgrade Flow

```bash
# Fresh install
curl -fsSL https://raw.githubusercontent.com/bkochavy/openclaw-sentinel/main/install.sh | bash

# Upgrade from watchdog + backup
curl -fsSL .../install.sh | bash -- --migrate

# Setup wizard
./install.sh --setup

# Check installation health
./install.sh --check
```

The installer:
1. Detects existing watchdog/backup installations
2. Migrates configs into unified `sentinel.json`
3. Unloads old launchd/systemd units
4. Installs new sentinel service
5. Runs `--check` to verify

## 9. CLI Interface

```bash
# Run health check + recovery (normal scheduler invocation)
sentinel.sh

# Run backup only (skip health check)
sentinel.sh --backup-only

# Run health check only (skip backup)
sentinel.sh --health-only

# Force backup regardless of schedule
sentinel.sh --force-backup

# Dry run (log what would happen, no actions)
sentinel.sh --dry-run

# Show current state
sentinel.sh --status

# Reset incident state
sentinel.sh --reset-incident
```

## 10. Success Criteria

1. **Single service** replaces both watchdog and backup launchd/systemd units
2. **Strict health semantics** — validates `/healthz` JSON response, not just curl success
3. **Deterministic recovery tiers** — gateway restart and doctor fix run before any LLM invocation
4. **Pre-repair backup gate** — emergency snapshot before risky recovery actions
5. **Unified config** — one JSON file with clear sections
6. **Backward compatible** — auto-migrates from existing watchdog.json + backup.json
7. **Test coverage** — health probe, recovery tier logic, backup verification, state management
8. **Clean separation** — modular lib/ scripts, each < 200 lines
9. **Zero new dependencies** — bash + curl + jq + git (same as today)

## 11. Migration & Rollout

### Phase 1: Build & Test
- Implement sentinel.sh with modular lib/ structure
- Port all existing watchdog + backup functionality
- Add deterministic recovery tiers
- Add strict health probe
- Full test suite

### Phase 2: Beta
- Install alongside existing services (different timer name)
- Run in `--dry-run` mode for 48h to validate decisions
- Compare with existing watchdog/backup outputs

### Phase 3: Cutover
- Run `install.sh --migrate` to unload old services
- Monitor for 1 week
- Archive old repos or mark deprecated

### Phase 4: GitHub Release
- Rename repo to `openclaw-sentinel` (or new repo)
- Update README with migration guide
- Publish to ClawHub

## 12. Non-Goals (Explicit)

- Not replacing OpenClaw's built-in service manager or restart logic
- Not adding a web UI or dashboard
- Not supporting Windows (yet)
- Not handling multi-host orchestration
- Not doing full disk/VM snapshots (file-level config backup only)

## 13. Open Questions

1. Should we keep the repo name `openclaw-watchdog` and just evolve it, or create a new `openclaw-sentinel` repo?
2. Should backup push failures block recovery operations, or are they independent?
3. Should we add a `--restore` command for one-click system restore from backup?
