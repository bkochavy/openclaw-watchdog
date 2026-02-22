# openclaw-watchdog

> OpenClaw gateway goes down. This catches it in 10 minutes and repairs it automatically.

OpenClaw's process manager will try to restart the gateway. Sometimes it can't — bad config,
port conflict, broken update. This watchdog catches that, sends you a Telegram alert, and
launches Codex CLI to diagnose and fix it. If Codex can't fix it after 3 attempts, you get
a rescue mode where you reply directly with instructions.

Built and battle-tested on a Mac Mini running OpenClaw 24/7.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-compatible-orange)](https://openclaw.ai)

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
# Option 1: one-liner
OPENCLAW_WATCHDOG_CHAT_ID=YOUR_TELEGRAM_CHAT_ID \
  curl -fsSL https://raw.githubusercontent.com/bkochavy/openclaw-watchdog/main/install.sh | bash

# Option 2: clone and run
git clone https://github.com/bkochavy/openclaw-watchdog.git
cd openclaw-watchdog
./install.sh --setup
```

> **Note on channels:** Notifications require a Telegram bot token because the watchdog
> must operate independently of OpenClaw (which may be down). Discord/iMessage/Signal
> notifications require OpenClaw to be running, which defeats the purpose.
> Rescue mode (`/codex` commands) is Telegram-only by design.
> If you don't use Telegram, notifications are silently skipped — the watchdog still
> repairs, it just won't alert you.

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
