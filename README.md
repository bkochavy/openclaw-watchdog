# openclaw-sentinel

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-compatible-orange)](https://openclaw.ai)

`openclaw-sentinel` is a unified watchdog and backup service for OpenClaw gateways.

It replaces separate watchdog and backup timers with one scheduler-driven entrypoint that:
- Performs strict health checks against `/healthz` (`{"ok": true}` required)
- Runs deterministic recovery before coding-agent repair
- Runs system + memory backups on schedule
- Verifies backup freshness and sends deduplicated alerts
- Preserves incident state in atomic JSON files

## What It Does

Sentinel runs as a periodic oneshot job (launchd on macOS, systemd timer on Linux):
1. Acquire lock (`state/sentinel.lock`) with stale detection
2. Load unified config (`sentinel.json`) and state (`sentinel-state.json`)
3. Probe health (`/healthz`, fallback `openclaw gateway status --json`)
4. If healthy: run backup cycle (if due), then backup health check
5. If unhealthy: run tiered recovery with incident tracking
6. Release lock

Recovery tiers are strictly ordered:
1. `openclaw gateway restart`
2. `openclaw doctor --fix --non-interactive`
3. Config rollback from backup
4. Coding agent repair (Codex/Claude)
5. Telegram rescue mode

Before tier 3+ actions, sentinel verifies backup freshness and creates an emergency backup if needed.

## Architecture Overview

Core modules in `scripts/lib/`:
- `config.sh`: config defaults, loading, helper getters, legacy migration
- `state.sh`: JSON state init/read/write, incident lifecycle, backup snapshot metadata
- `lock.sh`: lock acquire/release, stale detection by PID + age
- `health.sh`: strict health probe and fallback probe, `wait_for_ok`
- `notify.sh`: unified Telegram + Discord notifications
- `recovery.sh`: tier escalation, cooldown logic, agent resolution, rescue mode
- `backup.sh`: schedule checks, system backup, manifest generation, dedup alerts
- `backup-memory.sh`: memory/session backup snapshots
- `tg-helper.sh`: Telegram runtime helper for rescue-mode agent workflows

Main entrypoint: `scripts/sentinel.sh`.

## Install

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/bkochavy/openclaw-sentinel/main/install.sh | bash
```

### Local install

```bash
git clone https://github.com/bkochavy/openclaw-sentinel.git
cd openclaw-sentinel
./install.sh
```

### Installer flags

```bash
# interactive setup wizard
./install.sh --setup

# non-interactive setup (OPENCLAW_SENTINEL_CHAT_ID optional)
./install.sh --setup --quiet

# migrate legacy watchdog/backup configs into sentinel.json
./install.sh --migrate

# verify installation only
./install.sh --check
```

### Requirements

- `openclaw`
- `bash`
- `curl`
- `jq`
- `git`

## Config Reference

Default config path: `~/.openclaw/sentinel.json`.

Full example: [`sentinel.example.json`](/private/tmp/sentinel-build/sentinel.example.json).

### Top-level

| Key | Type | Default | Purpose |
|---|---|---|---|
| `health_url` | string | `http://127.0.0.1:18789/healthz` | Primary gateway health endpoint |
| `check_interval_seconds` | int | `300` | Scheduler interval metadata |
| `state_file` | string(path) | `~/.openclaw/state/sentinel-state.json` | Runtime state JSON |
| `lock_file` | string(path) | `~/.openclaw/state/sentinel.lock` | Concurrency lock JSON |
| `recovery_log` | string(path) | `~/.openclaw/workspace/memory/recovery-log.md` | Recovery journal path |
| `log_dir` | string(path) | `~/.openclaw/logs` | Sentinel logs directory |

### `recovery`

| Key | Type | Default |
|---|---|---|
| `max_failures_before_action` | int | `2` |
| `cooldown_seconds` | int | `1800` |
| `max_repairs_per_incident` | int | `3` |
| `deterministic_restart_enabled` | bool | `true` |
| `deterministic_doctor_enabled` | bool | `true` |
| `config_rollback_enabled` | bool | `true` |
| `codex_timeout_seconds` | int | `180` |
| `rescue_timeout_seconds` | int | `420` |
| `rescue_command_prefix` | string | `/codex` |
| `codex_model` | string | `gpt-5.3-codex` |
| `codex_bin` | string(path) | `""` |
| `claude_bin` | string(path) | `""` |

### `backup`

| Key | Type | Default |
|---|---|---|
| `enabled` | bool | `true` |
| `schedule` | string (`HH:MM`) | `04:00` |
| `system_backup_dir` | string(path) | `~/backups/openclaw-system` |
| `memory_backup_dir` | string(path) | `~/backups/openclaw-memory` |
| `github_repo` | string | `""` |
| `github_user` | string | `""` |
| `include_skills` | bool | `true` |
| `include_scripts` | bool | `true` |
| `include_launchd` | bool | `true` |
| `include_agents` | bool | `true` |
| `redact_env_values` | bool | `true` |
| `max_backup_age_hours` | int | `30` |
| `critical_files` | string[] | `openclaw/openclaw.json`, `workspace-config/AGENTS.md`, `workspace-config/SOUL.md` |

### `notifications`

| Key | Type | Default |
|---|---|---|
| `telegram_bot_token_env` | string | `TELEGRAM_BOT_TOKEN_AVA` |
| `telegram_chat_id` | string | `""` |
| `discord_webhook_url` | string | `""` |
| `notify_on_recovery` | bool | `true` |
| `notify_on_backup_failure` | bool | `true` |
| `notify_on_backup_success` | bool | `false` |

## CLI Flags

Run `scripts/sentinel.sh` directly (or installed `~/.openclaw/bin/sentinel.sh`):

| Flag | Behavior |
|---|---|
| _(none)_ | Normal health + recovery + backup flow |
| `--backup-only` | Skip health/recovery, run backup cycle |
| `--health-only` | Skip backup cycle, run health/recovery |
| `--force-backup` | Force backup regardless of schedule |
| `--dry-run` | Log mutating actions without executing them |
| `--status` | Print current JSON state |
| `--reset-incident` | Clear current incident and failure counter |
| `--migrate` | Build `sentinel.json` from legacy configs |
| `--help` | Print usage |

## Migration From watchdog + backup

Sentinel supports legacy `watchdog.json` and `backup.json` migration.

Recommended cutover:
1. Install sentinel with migration:
```bash
./install.sh --migrate
```
2. Confirm sentinel config exists:
```bash
cat ~/.openclaw/sentinel.json
```
3. Verify scheduler health:
```bash
./install.sh --check
```
4. Confirm old watchdog/backup timers are unloaded (installer handles this automatically).

`sentinel_config_load` behavior:
- Uses `sentinel.json` when present
- Else merges legacy watchdog + backup config fields
- Else uses built-in defaults

## Testing

Run module tests (TAP-style shell scripts):

```bash
bash tests/test_health.sh
bash tests/test_state.sh
bash tests/test_lock.sh
bash tests/test_config.sh
bash tests/test_recovery.sh
bash tests/test_backup.sh
bash tests/test_integration.sh
```

Legacy compatibility test is still available at `tests/test_watchdog.sh`.

## Contributing

1. Fork and create a feature branch.
2. Keep `scripts/lib/*.sh` focused and under 200 lines where possible.
3. Add or update tests for every behavior change.
4. Run all tests before opening a PR.
5. Keep dependencies limited to `bash`, `curl`, `jq`, and `git`.

Coding standards:
- Use JSON state/config updates through `jq`.
- Use atomic writes (`tmp` + `mv`) for mutable files.
- Never `source` writable state files.
- Keep deterministic recovery tiers before LLM escalation.

## Uninstall

```bash
# keep config
./uninstall.sh

# also remove ~/.openclaw/sentinel.json
./uninstall.sh --purge
```
