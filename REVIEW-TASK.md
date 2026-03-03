# Review Task

You are reviewing the openclaw-sentinel codebase for correctness, edge cases, and production readiness.

## What to Review

1. **scripts/lib/*.sh** — All 9 library modules. Check for:
   - Shell quoting issues (unquoted variables, word splitting risks)
   - jq filter correctness (especially in state.sh and config.sh)
   - Race conditions in lock.sh (TOCTOU between check and write)
   - Error handling gaps (what happens when jq/curl/git fails?)
   - Atomic write correctness in state.sh (temp file + mv pattern)

2. **scripts/sentinel.sh** — Main orchestrator. Check for:
   - Correct source order and dependency chain
   - Flag parsing edge cases
   - Lock cleanup on unexpected exit (trap handler)
   - Recovery flow: does it actually follow tier 0→1→2→3→4→5 correctly?

3. **Recovery tier logic** — Verify:
   - Tier 1 (restart) only fires if deterministic_restart_enabled=true
   - Tier 2 (doctor) only fires if tier 1 failed AND doctor enabled
   - Tier 3 (rollback) runs emergency backup first
   - Tier 4 (agent) respects cooldown
   - Tier 5 (rescue) only enters after max repairs exceeded

4. **Backup subsystem** — Verify:
   - Schedule detection math (should_run) handles timezone and edge cases
   - Manifest generation correctly counts files
   - GitHub push with retry logic
   - Memory backup never pushes to remote

5. **Config migration** — Verify:
   - Legacy watchdog.json + backup.json merge correctly
   - Missing fields fall back to defaults
   - Path expansion handles ~ correctly

6. **Install/uninstall** — Check:
   - Legacy service unloading (watchdog + backup units)
   - Template variable substitution
   - Permissions on installed files

7. **Tests** — Review test quality and coverage gaps

## Output

Write a REVIEW.md file with:
- Critical issues (must fix before release)
- Important issues (should fix)
- Minor issues (nice to fix)
- Suggestions (improvements)
- Overall assessment

Be specific — cite file names, line numbers, and exact code when flagging issues.
