# Independent Code Review

You are doing an independent review of openclaw-sentinel. Another reviewer (Claude Code) is also reviewing this codebase — your review should be independent and focus on different angles.

## Focus Areas

1. **Runtime correctness** — Actually trace the execution path for these scenarios:
   - Gateway healthy, backup not due → should exit quickly
   - Gateway healthy, backup due → should run full backup cycle
   - Gateway down for 2 checks → should trigger tier 1 restart
   - Gateway down, tier 1-3 all fail → should invoke coding agent
   - Gateway down, max repairs reached → should enter rescue mode
   - Concurrent sentinel invocations → lock should prevent double-run

2. **Shell portability** — Check bash constructs work on:
   - macOS (bash 3.2 default + bash 5 via homebrew)
   - Linux (bash 4+, Ubuntu/Debian)
   - Are there bashisms that break on older bash?

3. **Security** — Check for:
   - Command injection via config values (jq filters, curl args)
   - Telegram token exposure in logs or process lists
   - Lock file race conditions exploitable by other users
   - Unsafe temp file creation

4. **Performance** — Flag any:
   - Unnecessary subshells
   - Repeated jq invocations that could be batched
   - Slow paths in the hot (healthy) case

5. **Test quality** — Run the tests if possible, check:
   - Do mocks actually prevent real network/disk operations?
   - Are edge cases covered (empty config, missing jq, stale lock)?
   - Can tests run in parallel without interfering?

## Output

Write REVIEW-CODEX.md with concrete findings, ordered by severity. Fix any critical bugs you find directly (commit the fixes). For non-critical issues, just document them.
