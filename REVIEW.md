# Code Review: openclaw-sentinel

Reviewed: `scripts/lib/*.sh` (9 modules), `scripts/sentinel.sh`, `scripts/watchdog.sh`,
`install.sh`, `uninstall.sh`, `tests/*.sh`, templates.

---

## Critical Issues (must fix before release)

### 1. Subshell variable assignment in `sentinel_backup_push_remote` — push verification always false

**File:** `scripts/lib/backup.sh`, lines 96–102

```bash
( cd "$backup_dir" || exit 1
  ...
  if git push origin HEAD:main --quiet >/dev/null 2>&1; then
    SENTINEL_BACKUP_LAST_PUSH_VERIFIED="true"
    SENTINEL_BACKUP_LAST_PUSH_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi
)
```

Both `SENTINEL_BACKUP_LAST_PUSH_VERIFIED` and `SENTINEL_BACKUP_LAST_PUSH_AT` are assigned
inside a `( ... )` subshell. Shell variable assignments in subshells never propagate to the
parent. After this function returns, both variables retain the values set just before the
subshell (lines 92–93):

```bash
SENTINEL_BACKUP_LAST_PUSH_VERIFIED="false"
SENTINEL_BACKUP_LAST_PUSH_AT=""
```

Downstream in `sentinel_backup_run_cycle` (backup.sh:182):

```bash
sentinel_state_set_backup_snapshot "$STATE_FILE" "$SENTINEL_BACKUP_LAST_SYSTEM_AT" \
  "$SENTINEL_BACKUP_LAST_MEMORY_AT" "$SENTINEL_BACKUP_LAST_PUSH_AT" \
  "$SENTINEL_BACKUP_LAST_PUSH_VERIFIED" "$SENTINEL_BACKUP_LAST_MANIFEST_SHA"
```

`last_push_verified` is **always** recorded as `false` and `last_push_at` is always `""`,
regardless of whether the push actually succeeded. The state file will never accurately
reflect a verified push.

---

### 2. `timeout_seconds` parameter is accepted but never used in `sentinel_recovery_run_agent`

**File:** `scripts/lib/recovery.sh`, lines 26–35

```bash
sentinel_recovery_run_agent() {
  local timeout_seconds="$1" prompt="$2" agent kind bin
  ...
  if [ "$kind" = "codex" ]; then
    sentinel_recovery_exec "$bin" --dangerously-bypass-approvals-and-sandbox \
      --model "$RECOVERY_CODEX_MODEL" "$prompt"
  else
    sentinel_recovery_exec "$bin" --dangerously-skip-permissions "$prompt"
  fi
}
```

`timeout_seconds` is declared but never used. The agent is invoked with no timeout
enforcement. A hung agent (codex or claude) will block the sentinel process indefinitely,
preventing all further health checks and backups until the launchd/systemd timer kills
the process and retries.

The legacy `watchdog.sh` (lines 299–326) had a proper `run_with_timeout` function with
`timeout`, `gtimeout`, and a `python3` fallback. That mechanism was not ported to the new
sentinel. Call sites pass `$RECOVERY_CODEX_TIMEOUT` (recovery.sh:71) and
`$RECOVERY_RESCUE_TIMEOUT` (recovery.sh:91) — both are silently discarded.

---

### 3. TOCTOU race condition in `sentinel_lock_acquire`

**File:** `scripts/lib/lock.sh`, lines 84–98

```bash
sentinel_lock_acquire() {
  local file="$1"
  local stale_after_seconds="${2:-900}"

  if [ -f "$file" ]; then
    if sentinel_lock_is_stale "$file" "$stale_after_seconds"; then
      rm -f "$file"
    else
      return 1
    fi
  fi

  sentinel_lock_write "$file"   # ← TOCTOU window here
  return 0
}
```

Between the `[ -f "$file" ]` check and `sentinel_lock_write "$file"`, another process
can create its own lock file. Both processes then believe they hold the lock. Since the
launchd plist has `RunAtLoad true` and a 300-second interval, simultaneous launches are
unlikely — but not impossible during restart events or manual kicks.

A safe pattern would be `set -C` (noclobber) combined with redirect, `mkdir` atomicity, or
`ln -sn "$$" "$lock_file" 2>/dev/null`. The current `sentinel_lock_write` uses a
`mktemp` + `mv` pattern (lines 63–82), which is atomic for the write itself, but the
check-then-write sequence is not.

---

### 4. Telegram notifications corrupt messages containing `&` or `=`

**File:** `scripts/lib/notify.sh`, lines 61–65; `scripts/lib/tg-helper.sh`, lines 15–16

```bash
curl -fsS --max-time 10 "https://api.telegram.org/bot${SENTINEL_NOTIFY_TG_TOKEN}/sendMessage" \
  -d chat_id="$SENTINEL_NOTIFY_TG_CHAT" \
  -d text="$msg" \
  -d parse_mode="Markdown" >/dev/null 2>&1
```

`-d text="$msg"` sends the message as a URL-encoded form field. If `$msg` contains `&`,
curl splits it into additional form fields. If it contains `=`, curl interprets everything
before `=` as a new key. For example, a message like `"Recovery at tier 1 & 2"` becomes
`text=Recovery at tier 1 ` and a stray `2` field, truncating the notification.

This affects all Telegram sends: recovery announcements in `notify.sh:88`,
`tg-helper.sh:16`, and the runtime helper written by `sentinel_tg_write_runtime_helper`
(tg-helper.sh:108–115). The Discord webhook correctly uses
`jq -n --arg content "$msg" '{content: $content}'` (notify.sh:79) — the same approach
should be used for Telegram. The fix is to send JSON with `-H 'Content-Type: application/json'`
or to URL-encode the message with `--data-urlencode`.

---

## Important Issues (should fix)

### 5. Deterministic tiers 1 and 2 never increment `repairs_attempted`

**File:** `scripts/lib/recovery.sh`, lines 43–50

```bash
sentinel_recovery_try_deterministic() {
  local tier="$1" cmd_desc="$2"
  shift 2
  sentinel_state_set_tier "$STATE_FILE" "$tier"
  sentinel_recovery_log "sentinel: tier ${tier} - ${cmd_desc}"
  sentinel_recovery_exec "$@" >/dev/null 2>&1 || true
  sentinel_recovery_wait_check 45
}
```

This function does not call `sentinel_state_increment_repairs`. By contrast,
`sentinel_recovery_try_agent` (line 73) and `sentinel_recovery_rescue_mode` (line 93)
do call it. The consequence: if tiers 1 and 2 both fail and the function falls through to
tier 4 (agent), `repairs_attempted` is still 0. After the agent runs once,
`repairs_attempted` becomes 1. The `RECOVERY_MAX_REPAIRS` check (recovery.sh:108)
only limits agent invocations, not total repair attempts. This is inconsistent with the
naming and may be surprising to operators tuning `max_repairs_per_incident`.

---

### 6. Corrupted `sentinel.json` silently falls back to defaults

**File:** `scripts/lib/config.sh`, lines 128–130

```bash
if [ -f "$config_file" ]; then
  source_json="$(jq -c '.' "$config_file" 2>/dev/null || printf '{}\n')"
  SENTINEL_CONFIG_SOURCE="sentinel"
```

If the config file exists but contains invalid JSON, `jq` fails and `source_json` becomes
`{}`. The sentinel then runs on pure defaults with no warning. A corrupted config (e.g.,
after a failed mid-write) would be silently ignored, which could cause unexpected behavior
(wrong health URL, backup to wrong directory, etc.) that is hard to diagnose.

The stderr from `jq` is suppressed by `2>/dev/null`, so no error is surfaced to the log.
At minimum, this branch should emit a warning to `$LOG_DIR/sentinel.log` when the config
file exists but cannot be parsed.

---

### 7. `--dry-run` does not protect backup functions

**File:** `scripts/sentinel.sh`, line 37; `scripts/lib/recovery.sh`, lines 12–15

```bash
# recovery.sh
sentinel_recovery_exec() {
  if [ "${SENTINEL_DRY_RUN:-0}" = "1" ]; then sentinel_recovery_log "dry-run: $*"; return 0; fi
  "$@"
}
```

`SENTINEL_DRY_RUN` guards recovery commands via `sentinel_recovery_exec`, but backup
functions in `backup.sh` and `backup-memory.sh` have no such check. Running
`sentinel.sh --dry-run` will still:
- Perform real `git add -A` / `git commit` in the backup repositories (backup.sh:140, 143)
- Do real `rsync --delete` on memory files (backup-memory.sh:10)
- Attempt a real `git push` to GitHub (backup.sh:98)

---

### 8. Manifest `git_sha` field is stale by one commit

**File:** `scripts/lib/backup.sh`, lines 73–74, 140–143

```bash
echo "git_sha: $(git -C "$backup_dir" rev-parse HEAD 2>/dev/null || true)"
```

This `git_sha` is written into `backup-manifest.txt` before the manifest file itself is
committed (line 143). The SHA captured is the SHA of the backup content commit (line 140),
not the manifest commit. After the manifest is committed, HEAD advances to a new SHA.
`SENTINEL_BACKUP_LAST_MANIFEST_SHA` (line 144) then captures the manifest commit's SHA.
So the SHA stored in the manifest file and the SHA in state diverge by one commit.

---

### 9. `sentinel_backup_should_run` schedule parsing is fragile

**File:** `scripts/lib/backup.sh`, lines 40–52

```bash
hh="${schedule%:*}"; mm="${schedule#*:}"
hh="${hh:-04}"; mm="${mm:-00}"
```

- If `schedule` is `"04"` (no colon): `hh="04"`, `mm="04"` (entire string) — wrong minute.
- If `schedule` is `"04:00:00"` (extra colon): `hh="04"`, `mm="00:00"` — date parse fails.
- If `today_epoch` is 0 due to a parse failure, line 51 unconditionally returns 0
  (run backup), causing backup on every invocation.

No validation of the format is performed. A `[[ "$schedule" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]`
guard would prevent silent misfires.

---

### 10. `check_install` does not verify lib scripts

**File:** `install.sh`, lines 155–173

```bash
[ -x "$BIN_DIR/sentinel.sh" ] || { ... }
[ -x "$BIN_DIR/tg-helper.sh" ] || { ... }
```

`install_scripts` copies 9 lib modules to `$LIB_DIR` (install.sh:117). But `check_install`
only checks for `sentinel.sh` and `tg-helper.sh`. If `install -m 0755` fails for any lib
file (e.g., permissions issue), the install check still passes, and sentinel.sh will fail
at runtime when sourcing the missing lib.

---

### 11. Default `codex_model` references a non-existent model

**File:** `scripts/lib/config.sh`, line 29; `sentinel.example.json`, line 14

```json
"codex_model": "gpt-5.3-codex"
```

No such model exists in OpenAI's or Codex's API. This will cause agent repair attempts to
fail immediately when codex is selected. The default should reference a real model name
(e.g., `"o4-mini"` or another current model name, left for the operator to configure).

---

## Minor Issues (nice to fix)

### 12. `--backup-only` and `--health-only` silently override each other

**File:** `scripts/sentinel.sh`, lines 63–65

```bash
--backup-only) RUN_HEALTH=0; RUN_BACKUP=1 ;;
--health-only) RUN_HEALTH=1; RUN_BACKUP=0 ;;
```

Passing both flags causes the last one to win with no warning. Operators testing flags in
unfamiliar orders get silently wrong behavior. A check at the end of `sentinel_parse_args`
could detect and reject the combination.

---

### 13. `LOG_DIR` undefined when `sentinel_log` is called before config loads

**File:** `scripts/sentinel.sh`, lines 55–58; sentinel.sh line 120

`sentinel_log` uses `$LOG_DIR` (line 57). `LOG_DIR` is not set until
`sentinel_load_runtime_config` completes (line 120). If `sentinel_config_load` fails early
(e.g., jq missing), the script exits via `set -e`, but any library error message that
tries to call `sentinel_log` during that window would produce `mkdir -p ""` and a log
write to a bad path. This is a latent issue on first install with missing dependencies.

---

### 14. `sentinel_backup_memory_run` always returns 0; failure is silent

**File:** `scripts/lib/backup-memory.sh`, lines 60–62

```bash
SENTINEL_MEMORY_BACKUP_SHA="$(sentinel_backup_memory_commit "$backup_dir" "memory: $timestamp" 2>/dev/null || true)"
return 0
```

All errors from `sentinel_backup_memory_commit` are suppressed by `2>/dev/null || true`.
The function always returns 0 and the caller (backup.sh:181) always sets
`SENTINEL_BACKUP_LAST_MEMORY_AT` to the current time, even if git commit completely failed.
The state file records a "last memory backup" timestamp that may reflect a failed attempt.

---

### 15. Recovery module directly accesses `SENTINEL_NOTIFY_TG_TOKEN`

**File:** `scripts/lib/recovery.sh`, line 87

```bash
cmd="$(sentinel_tg_fetch_prefixed_command "$SENTINEL_NOTIFY_TG_TOKEN" \
  "$SENTINEL_NOTIFY_TG_CHAT" "$RECOVERY_RESCUE_PREFIX" "$RECOVERY_OFFSET_FILE" || true)"
```

`SENTINEL_NOTIFY_TG_TOKEN` and `SENTINEL_NOTIFY_TG_CHAT` are internal state variables of
`notify.sh`, not a public API. `recovery.sh` depends on `notify.sh`'s internal variable
names. This creates implicit coupling: renaming those variables in `notify.sh` silently
breaks rescue mode with no compiler or test to catch it.

---

### 16. Systemd service hardcodes `OPENCLAW_HOME` path

**File:** `templates/systemd/openclaw-sentinel.service`, line 10

```ini
ExecStart=%h/.openclaw/bin/sentinel.sh
```

Unlike the launchd plist (which is processed by `sed` substitution in `install_launchd`),
the systemd service is installed verbatim (install.sh:149). The path
`%h/.openclaw/bin/sentinel.sh` is hardcoded. If `OPENCLAW_HOME` is set to a non-default
location during install, the systemd service will point to the wrong binary and silently
fail to execute.

---

### 17. `install.sh` leaves temp file if `run_setup_wizard` exits mid-function

**File:** `install.sh`, lines 105–111

```bash
tmp="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")"
jq ... "$CONFIG_PATH" > "$tmp"
mv "$tmp" "$CONFIG_PATH"
```

`tmp` is not declared `local`. If `jq` fails (e.g., `CONFIG_PATH` contains invalid JSON
from a partial previous write), the script exits via `set -e`, leaving the
`sentinel.json.tmp.XXXXXX` orphan. The exit trap only cleans up `TMP_REPO`, not this file.

---

### 18. `test_watchdog.sh` tests the legacy `watchdog.sh`, not `sentinel.sh`

**File:** `tests/test_watchdog.sh`

`WATCHDOG_SCRIPT="$ROOT_DIR/scripts/watchdog.sh"`. The tests use the old shell-variable
state format (`FAILURES=2`, `LAST_REPAIR=0`), old config keys (`max_failures` not
`max_failures_before_action`), and old health URL format (without `/healthz` path). These
tests verify the legacy code — not the new sentinel.

Coverage gap: `test_integration.sh` has only 2 end-to-end scenarios. There are no tests
for the `--status`, `--reset-incident`, `--migrate`, or `--force-backup` flags of the
new sentinel.sh, and no tests for notify.sh or tg-helper.sh.

---

### 19. `sentinel_backup_manifest_fresh` uses filesystem mtime, not backup timestamp

**File:** `scripts/lib/backup.sh`, lines 149–156

```bash
if [ "$(uname -s)" = "Darwin" ]; then
  mtime="$(stat -f %m "$manifest" 2>/dev/null || printf '0')"
...
age="$(( (now - mtime) / 3600 ))"
```

Freshness of the manifest is determined by its filesystem mtime, not by the timestamp
recorded inside it. A `touch backup-manifest.txt` would make a stale backup appear fresh.
Conversely, if the backup directory is on a network filesystem with skewed clocks, this
check could misfire. The state file already records `last_system_backup_at` — that field
would be a more authoritative source than mtime.

---

### 20. `backup.sh` git commits use implicit git user identity

**File:** `scripts/lib/backup.sh`, lines 140, 143; `scripts/lib/backup-memory.sh`, line 35

```bash
git commit -m "backup: $timestamp" --quiet
```

If `user.email` and `user.name` are not configured in the global or local git config,
these commits will fail with "Author identity unknown" on a fresh machine. The integration
test (test_integration.sh:191–194) sets `GIT_AUTHOR_*` env vars, which masks this in
tests. In production, `sentinel_backup_git_prepare` should either set `user.email` /
`user.name` on the local repo or document the requirement.

---

## Suggestions

### A. Reinstate timeout enforcement for agent runs

The old `watchdog.sh` (lines 287–326) had a robust `run_with_timeout` that used the
system `timeout` command with a `gtimeout` fallback and a `python3` escape hatch.
`sentinel_recovery_run_agent` should wrap the agent call the same way, using the
`$timeout_seconds` it already accepts as parameter.

### B. Use atomic lock creation

Replace the check-then-write in `sentinel_lock_acquire` with:
```bash
mkdir "$file.lock" 2>/dev/null || return 1
# write JSON into $file.lock/, then mv to $file
```
Or use `( set -C; printf ... > "$file" ) 2>/dev/null` (noclobber). This eliminates the
TOCTOU window entirely.

### C. Send Telegram messages as JSON

```bash
curl -fsS --max-time 10 \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg chat "$SENTINEL_NOTIFY_TG_CHAT" \
             --arg text "$msg" \
             '{chat_id: $chat, text: $text, parse_mode: "Markdown"}')" \
  "https://api.telegram.org/bot${SENTINEL_NOTIFY_TG_TOKEN}/sendMessage"
```

This is already done correctly for Discord (notify.sh:79). Apply the same approach to
Telegram to avoid form-encoding pitfalls.

### D. Warn on config fallback

When `sentinel.json` exists but fails to parse, emit a warning rather than silently
continuing:
```bash
source_json="$(jq -c '.' "$config_file" 2>/dev/null)"
if [ -z "$source_json" ]; then
  printf 'sentinel: WARNING: config %s is invalid JSON, using defaults\n' "$config_file" >&2
  source_json='{}'
fi
```

### E. Add `--dry-run` guards to backup functions

`SENTINEL_DRY_RUN` should gate the mutating operations in `sentinel_backup_run_system`:
git commits, `cp`, `rm -rf`, and especially `git push`.

### F. Fix the push verification subshell

Extract the push logic out of the subshell or use a process substitution approach
to capture the result back into the parent. The simplest fix:

```bash
( cd "$backup_dir" || exit 1
  git remote ... || true
  git push origin HEAD:main --quiet >/dev/null 2>&1
)
if [ $? -eq 0 ]; then
  SENTINEL_BACKUP_LAST_PUSH_VERIFIED="true"
  SENTINEL_BACKUP_LAST_PUSH_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi
```

### G. Validate `backup.schedule` format on load

Add a format guard in `sentinel_config_load` or `sentinel_load_runtime_config`:
```bash
[[ "$BACKUP_SCHEDULE" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || {
  printf 'sentinel: invalid backup.schedule "%s", defaulting to 04:00\n' "$BACKUP_SCHEDULE" >&2
  BACKUP_SCHEDULE="04:00"
}
```

### H. Test coverage gaps

Currently untested:
- `notify.sh` (Telegram/Discord send paths)
- `tg-helper.sh` (offset priming, command fetch logic)
- `install.sh` / `uninstall.sh` (setup wizard, migration flag, check mode)
- `sentinel.sh` flags: `--status`, `--reset-incident`, `--force-backup`, `--migrate`
- Agent timeout enforcement (which doesn't work at all — see Critical #2)
- Memory backup never pushes: confirmed correct (`backup-memory.sh` has no `push_remote`
  call), but not covered by a test assertion

---

## Recovery Tier Logic Verification

Per REVIEW-TASK.md requirements:

| Requirement | Verdict |
|---|---|
| Tier 1 only fires if `deterministic_restart_enabled=true` | ✅ `recovery.sh:111` |
| Tier 2 only fires if tier 1 failed AND doctor enabled | ✅ `tier < 2` guard correct |
| Tier 3 runs emergency backup first | ✅ `sentinel_backup_ensure_recent_for_repair` called at `recovery.sh:55` |
| Tier 4 respects cooldown | ✅ `[ "$tier" -ge 4 ] && [ "$elapsed" -lt ...]` at `recovery.sh:109` |
| Tier 5 only after max repairs exceeded | ✅ `[ "$repairs" -ge "$RECOVERY_MAX_REPAIRS" ]` at `recovery.sh:108` |
| Memory backup never pushes to remote | ✅ `backup-memory.sh` has no `push_remote` call |
| Tier 3 skipped if no recent backup available | ✅ `recovery.sh:56` returns 1 on failure |

The tier sequencing is correct. The repair cooldown is only checked when `tier >= 4`,
meaning deterministic tiers 1–3 fire without delay between invocations — which is
intentional since they're fast and non-destructive.

Note: The cooldown check uses `elapsed = now - epoch(last_repair_at)`. When
`last_repair_at` is `""`, `sentinel_recovery_to_epoch` returns `0`, so `elapsed` becomes
the current epoch (≈1.7 billion seconds) — always greater than cooldown. First-time agent
invocations therefore fire immediately. This is correct.

---

## Backup Subsystem Verification

| Check | Verdict |
|---|---|
| `sentinel_backup_should_run` force flag | ✅ `backup.sh:39` |
| `sentinel_backup_should_run` timezone edge (today vs yesterday window) | ✅ `backup.sh:52` |
| Manifest counts files per subdirectory | ✅ `backup.sh:77-81` |
| Critical file presence recorded in manifest | ✅ `backup.sh:83-86` |
| GitHub push retry logic | ❌ No retry; single attempt only (`backup.sh:98`) |
| Push verification state propagated | ❌ Lost in subshell (Critical #1) |
| Memory backup never pushes to remote | ✅ `backup-memory.sh` confirmed |
| `rsync --delete` removes files deleted from source | ✅ intentional, but risky if src path wrong |

---

## Config Migration Verification

| Check | Verdict |
|---|---|
| `max_failures` → `recovery.max_failures_before_action` | ✅ `config.sh:86` |
| `backup_dir` → `backup.system_backup_dir` | ✅ `config.sh:98` |
| `rescue_command_timeout_seconds` → `recovery.rescue_timeout_seconds` | ✅ `config.sh:90` |
| Missing fields fall back to defaults via `$a * $b` merge | ✅ `config.sh:138` |
| `~` expansion in path fields | ✅ `sentinel_expand_path` in `config.sh:4-11` |
| `~VAR/path` (non-HOME tilde) not expanded | ⚠️ Only `~/` prefix handled; `~user/` left as-is |

---

## Install/Uninstall Verification

| Check | Verdict |
|---|---|
| Legacy watchdog unit unloaded on Darwin | ✅ `install.sh:124` |
| Legacy backup unit unloaded on Linux | ✅ `install.sh:129-131` |
| Template substitution for launchd plist | ✅ `install.sh:139-140` |
| Template substitution for systemd | ❌ No substitution; hardcoded `%h/.openclaw/bin/sentinel.sh` |
| Permissions: sentinel.sh / lib files | ✅ `install -m 0755` |
| Permissions: systemd units | ✅ `install -m 0644` |
| `uninstall.sh --purge` removes config | ✅ `uninstall.sh:50` |
| `uninstall.sh` removes lib dir | ✅ `rm -rf "$BIN_DIR/lib"` at `uninstall.sh:47` |

---

## Overall Assessment

The codebase is well-structured and shows clear thinking about the recovery tier model,
state management, and config migration. The JSON state + atomic writes pattern in
`state.sh` is solid. Test coverage for the core modules (lock, state, config, health,
recovery orchestration, backup scheduling) is good.

However, **three critical bugs will silently prevent production functionality**:

1. **Push verification is always false** — backup push success is never recorded.
2. **Agent runs without timeout** — a hung agent freezes the sentinel permanently.
3. **Telegram messages with `&` or `=` are silently corrupted** — operator notifications
   (the primary operational channel) can be truncated or garbled exactly when they matter
   most (during incidents).

The TOCTOU race in lock acquisition is unlikely to trigger in normal launchd/systemd
scheduling but could bite on rapid manual re-runs or restart events.

All four critical issues have straightforward fixes. The rest of the codebase is
production-quality.
