# REVIEW-CODEX: Independent Code Review (openclaw-sentinel)

## Scope and Method
I reviewed the sentinel runtime and supporting modules with focus on:
- runtime correctness across the required recovery/backup scenarios,
- bash portability (macOS bash 3.2 + Linux bash 4+),
- security posture (injection/secrets/lock safety/temp files),
- hot-path performance,
- test quality and isolation.

I traced execution directly in `scripts/sentinel.sh` and `scripts/lib/*.sh`, ran the full test suite, added targeted race/timeout tests, and reproduced concurrency behavior under load.

## Scenario Trace Summary
1. Gateway healthy, backup not due: **Pass** (health path resets incident and returns quickly except backup health check)
   - Flow: `scripts/sentinel.sh:157-168` + `scripts/lib/backup.sh:174-185`
2. Gateway healthy, backup due: **Pass** (system + memory backup + state snapshot)
   - Flow: `scripts/lib/backup.sh:178-183`
3. Gateway down for 2 checks: **Pass** tier gate then deterministic recovery
   - Flow: `scripts/sentinel.sh:166-167` + `scripts/lib/recovery.sh:147-160`
4. Gateway down, tiers 1-3 fail: **Pass** escalates to coding agent
   - Flow: `scripts/lib/recovery.sh:159-164`
5. Gateway down, max repairs reached: **Pass** enters rescue mode tier 5
   - Flow: `scripts/lib/recovery.sh:156-157`
6. Concurrent invocations: **Failed before fix, now Pass**
   - Fixed in `scripts/lib/lock.sh:94-120` with atomic link-based acquisition.

## Findings (Ordered by Severity)

### Critical (Fixed)
1. **Non-atomic lock acquisition allowed concurrent runs**
   - File: `scripts/lib/lock.sh` (pre-fix `sentinel_lock_acquire` + `sentinel_lock_write`)
   - Impact: Multiple sentinel invocations could run at once, violating core correctness and creating conflicting repairs/backups.
   - Repro: 24 parallel contenders acquired the same lock in one round.
   - Fix: Reworked lock acquire to atomic creation via `ln` against a prepared JSON payload; release now only removes lock when owned by current PID.
   - Verification: Added contention tests in `tests/test_lock.sh:151-181`.

2. **Recovery timeout settings were ignored**
   - File: `scripts/lib/recovery.sh` (pre-fix `sentinel_recovery_run_agent` ignored `timeout_seconds` arg)
   - Impact: Tier 4/5 repair commands could hang indefinitely, blocking scheduler cadence and incident progression.
   - Fix: Added `sentinel_recovery_exec_with_timeout` with `timeout`/`gtimeout`/`python3` fallback and wired tier 4/5 agent execution through it.
   - Verification: Added test `tests/test_recovery.sh:237-280` to assert timeout wrapper receives configured seconds.

### High
3. **Telegram bot token is exposed in process arguments**
   - Files: `scripts/lib/notify.sh:61`, `scripts/lib/tg-helper.sh:15`, `scripts/lib/tg-helper.sh:22`, `scripts/lib/tg-helper.sh:48`, `scripts/lib/tg-helper.sh:81`, runtime helper block `scripts/lib/tg-helper.sh:113-127`
   - Impact: Local users can read token via process list while `curl` is running.
   - Recommendation: Call `curl` with config from stdin (`curl --config -`) so URL/token never appears in argv.

### Medium
4. **Backup push verification state is never updated to true after successful push**
   - File: `scripts/lib/backup.sh:90-103`
   - Cause: Success assignments occur inside a subshell, so parent-shell globals remain unchanged.
   - Impact: `last_push_verified`/`last_push_at` in state can be inaccurate even when push succeeds.
   - Recommendation: Run `git push` in a conditional subshell and assign state variables in parent shell.

5. **Environment bootstrap imports arbitrary variables from user-writable env files**
   - File: `scripts/lib/notify.sh:15-42`
   - Impact: Values like `PATH` can be overridden before command execution, expanding command-hijack surface if env files are compromised.
   - Recommendation: Allowlist only required notification keys (or minimally block sensitive shell/runtime vars).

### Low (Performance)
6. **Hot healthy path performs many repeated `jq` invocations during config load**
   - File: `scripts/sentinel.sh:78-125`
   - Impact: Extra process overhead every 5-minute tick (small but avoidable).
   - Recommendation: Batch extraction from `SENTINEL_CONFIG_JSON` once per section to reduce forks.

## Test Quality Assessment
- Positives:
  - Tests are isolated via per-test temp dirs and mock binaries.
  - Network/system side effects are mostly mocked in health/integration/recovery tests.
  - Core state and deterministic recovery logic are covered.
- Gaps still open:
  - No explicit integration test for healthy + backup-not-due fast path.
  - No integration test forcing tier 1-3 failure through tier 4/5 in `scripts/sentinel.sh` end-to-end.
  - No test for missing `jq` behavior in top-level sentinel invocation.

## Validation Run
Executed all test scripts after fixes:
- `tests/test_backup.sh`
- `tests/test_config.sh`
- `tests/test_health.sh`
- `tests/test_integration.sh`
- `tests/test_lock.sh`
- `tests/test_recovery.sh`
- `tests/test_state.sh`
- `tests/test_watchdog.sh`

All passed.
