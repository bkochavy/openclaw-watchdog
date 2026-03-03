# Build Instructions

You are building **openclaw-sentinel** — a unified gateway watchdog and backup management system for OpenClaw.

## Source Materials

1. **PRD.md** — Full product requirements. Read this FIRST. It defines architecture, config schema, file structure, recovery tiers, and success criteria.
2. **scripts/watchdog.sh** — Existing watchdog (817 lines). Port the good parts (Telegram rescue mode, config loading, coding agent integration). Fix the bad parts (health check, no deterministic restart, shell-sourced state).
3. **scripts/lib/tg-helper.sh** — Existing Telegram helper. Clean up and integrate.
4. **backup-ref-scripts/** — Reference backup implementation. Port system backup, memory backup, backup-healthcheck, and backup-apply into the sentinel's lib/ modules.
5. **install.sh** — Existing installer. Evolve for unified sentinel.
6. **templates/** — Existing launchd/systemd templates. Update names/labels.
7. **tests/test_watchdog.sh** — Existing test suite. Expand significantly.

## Implementation Order

1. Read PRD.md completely
2. Create the file structure from PRD section 7
3. Implement lib/ modules bottom-up:
   - `lib/config.sh` — config loading, migration from legacy formats
   - `lib/state.sh` — JSON state with atomic writes
   - `lib/lock.sh` — JSON lock with stale detection
   - `lib/health.sh` — strict /healthz probe + fallback
   - `lib/notify.sh` — Telegram + Discord unified notifications
   - `lib/recovery.sh` — tiered recovery (tiers 0-5)
   - `lib/backup.sh` — system backup (port from backup-ref-scripts/backup.sh)
   - `lib/backup-memory.sh` — memory backup (port from backup-ref-scripts/backup-memory.sh)
   - `lib/tg-helper.sh` — runtime TG helper for coding agents
4. Implement `scripts/sentinel.sh` — main entry point with CLI flags
5. Update `install.sh` for unified sentinel
6. Update `uninstall.sh`
7. Create `sentinel.example.json`
8. Write tests for each module
9. Update `README.md`

## Quality Standards

- Each lib/ file should be < 200 lines
- All functions should have clear names and brief comments
- Use `jq` for JSON manipulation (required dependency)
- Atomic state writes: write to temp file, then `mv`
- Test every function that makes a decision
- ShellCheck clean (no warnings)
- Don't use `source` on untrusted/writable state files
- Health check MUST validate JSON body `ok: true`, not just curl success
- Recovery MUST follow tier order: restart → doctor → rollback → LLM → rescue
- Backup gate MUST check for recent backup before tier 3+ repairs

## What NOT to Do

- Don't add Node.js/Python dependencies (bash + curl + jq + git only, python3 optional for timeout fallback)
- Don't change the Telegram rescue mode UX (it works well)
- Don't remove support for Codex or Claude Code as repair agents
- Don't hardcode any paths — everything through config with sensible defaults
- Don't skip tests
