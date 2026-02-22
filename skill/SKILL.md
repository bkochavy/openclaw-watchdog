---
name: openclaw-watchdog
description: "Manage the OpenClaw gateway watchdog. Use when: gateway is down, watchdog alerts arrive, user wants to check watchdog status, tune repair behavior, read recovery logs, or manually trigger a repair cycle."
---

## Purpose
Operate, debug, and tune the OpenClaw gateway watchdog package.

## Agent runbook
- Check watchdog status
  - macOS: `launchctl list | grep watchdog`
  - Linux: `systemctl --user status openclaw-watchdog.timer`
- View watchdog state: `cat /tmp/openclaw-watchdog-state`
- View recent logs: `tail -50 ~/.openclaw/logs/watchdog.log`
- Trigger a manual cycle: `bash ~/.openclaw/bin/watchdog.sh`
- Reset incident tracking: `rm -f /tmp/openclaw-watchdog-state`
- Tune thresholds/timeouts: edit `~/.openclaw/watchdog.json`

## Check if repair is currently running
- Lock file path is config-driven (`lock_file`, default `/tmp/openclaw-watchdog.lock`)
- If it exists, inspect PID:
  - `cat /tmp/openclaw-watchdog.lock`
  - `kill -0 <pid> && echo "running" || echo "stale lock"`

## Send a test Telegram alert
- Source helper and send a message:
  - `source ~/.openclaw/bin/tg-helper.sh`
  - `export TG_TOKEN="$(printenv TELEGRAM_BOT_TOKEN_AVA)"`
  - `export TG_CHAT="<chat-id>"`
  - `tg_send "🧪 watchdog test alert"`

## Force rescue mode
- Option 1: Set `max_repairs_per_incident` to `0` in `~/.openclaw/watchdog.json` and run watchdog once.
- Option 2: Set state values manually:
  - `REPAIRS_THIS_INCIDENT=<max_repairs_per_incident>`
  - `RESCUE_ANNOUNCED=0`
  - then run `bash ~/.openclaw/bin/watchdog.sh`.

## Recovery log format
Each repair attempt appends markdown to `~/.openclaw/workspace/memory/recovery-log.md`:
```markdown
## Recovery - YYYY-MM-DD HH:MM:SS
- **Attempt:** #N
- **Root cause:** ...
- **Fix applied:** ...
- **Result:** recovered | still down
```
