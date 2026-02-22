## 👤 For Humans

### The problem
OpenClaw gateway can crash hard enough that the service manager cannot recover it (bad config, port conflict, broken dist patch). If that happens silently, your assistant stops replying until you manually notice.

### What this does
- Checks gateway health every 5 minutes
- After 2 consecutive failures (~10 minutes), sends a Telegram alert and launches Codex CLI repair
- Codex can send live Telegram updates while it works (`-codexrecov` suffix)
- If auto-repair fails 3 times, enters rescue mode: reply with `/codex <instruction>` and the watchdog routes it to Codex
- When gateway recovers, sends a recovery confirmation
- Writes incident details to `~/.openclaw/workspace/memory/recovery-log.md`

### Install
```bash
git clone https://github.com/<your-org>/openclaw-watchdog.git
cd openclaw-watchdog
./install.sh --setup
```

### Reading alerts
- `🔴` down alert: threshold reached, Codex repair cycle starting
- `🔧` repairing alert: active repair attempt in progress
- `🚨` rescue mode: auto-attempt budget exhausted, manual `/codex` commands enabled
- `🟢` recovered alert: health restored

### Rescue mode
Use:
```text
/codex <instruction>
```
Example:
```text
/codex inspect gateway.err.log and fix startup crash
```

## 🤖 For Agents

### Runbook
- Check watchdog status
  - macOS: `launchctl list | grep watchdog`
  - Linux: `systemctl --user status openclaw-watchdog.timer`
- View state: `cat /tmp/openclaw-watchdog-state`
- View recent activity: `tail -50 ~/.openclaw/logs/watchdog.log`
- Trigger manual repair cycle: `bash ~/.openclaw/bin/watchdog.sh`
- Reset after incident: `rm -f /tmp/openclaw-watchdog-state`
- Tune behavior: edit `~/.openclaw/watchdog.json`

### Exit codes
- `0`: normal run (healthy, waiting, repairing, rescue polling, or skipped due to lock)
- `1`: configuration/dependency error (for example config exists but `jq` missing)

### Useful files
- Config: `~/.openclaw/watchdog.json`
- Runtime tg helper: `${TMPDIR:-/tmp}/openclaw-tg-helper.sh`
- Logs: `~/.openclaw/logs/watchdog.log`
- Recovery journal: `~/.openclaw/workspace/memory/recovery-log.md`
