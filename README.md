# openclaw-watchdog

![openclaw-watchdog](https://raw.githubusercontent.com/bkochavy/openclaw-watchdog/main/.github/social-preview.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-compatible-orange)](https://openclaw.ai)

**Your [OpenClaw](https://openclaw.ai) gateway crashes at 2 AM. You wake up to a Telegram message: "Auto-repair successful, gateway is back online." You go back to sleep.**

OpenClaw's service manager handles normal restarts, but some failures stick — bad config, port conflicts, a broken update. When that happens, your AI assistant silently stops responding and nobody notices until you check.

This watchdog catches those hard crashes, sends you a Telegram alert, and launches a coding agent (Codex or Claude Code) to diagnose and fix it automatically. If the agent can't fix it after 3 tries, you get rescue mode: reply with instructions from your phone and the watchdog routes them to the agent while the gateway is still down.

Works on any [OpenClaw](https://openclaw.ai) install — macOS and Linux.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bkochavy/openclaw-watchdog/main/install.sh | bash
```

The installer runs a setup wizard that asks for your Telegram chat ID and configures the system scheduler (launchd on macOS, systemd on Linux). Health checks start at load on macOS, within ~2 minutes on Linux, then continue every 5 minutes.

> **Don't use Telegram?** That's fine. Skip the chat ID and the watchdog still auto-repairs, it just won't alert you.

<details>
<summary>Alternative: clone and configure manually</summary>

```bash
git clone https://github.com/bkochavy/openclaw-watchdog.git
cd openclaw-watchdog
./install.sh --setup
```

For CI or unattended installs, pass your chat ID as an env var:
```bash
OPENCLAW_WATCHDOG_CHAT_ID=123456789 ./install.sh --quiet
```
</details>

### Requirements

| Dependency | Purpose | Install |
|---|---|---|
| `openclaw` | gateway runtime + CLI used by repairs | `curl -fsSL https://openclaw.ai/install.sh | bash` |
| `bash`, `curl` | runtime + health checks | pre-installed on macOS/Linux |
| `jq` | config & Telegram API parsing | `brew install jq` / `apt install jq` |
| `python3` | setup wizard + timeout fallback | `brew install python3` / `apt install python3` |
| `codex` or `claude` | coding agent for auto-repair | `npm i -g @openai/codex` or `npm i -g @anthropic-ai/claude-code` |

The installer will try to install `jq` automatically if it's missing.

---

## How it works

```
Gateway healthy ─── watchdog checks every 5 min ─── all clear, do nothing
                                                          │
Gateway down ────── 1st failure: note it, wait ───────────┘
                    2nd failure (~10 min): trigger repair
                         │
              ┌──────────┴──────────┐
              │  Coding agent runs  │
              │  diagnoses + fixes  │
              │  sends TG updates   │
              └──────────┬──────────┘
                         │
              ┌────── recovered? ──────┐
              yes                      no
               │                  retry (up to 3x)
          TG: "back online"            │
                              enters rescue mode
                              you reply from phone
```

### What the alerts look like

| Alert | Meaning |
|---|---|
| `🔴 Gateway down for ~10 minutes...` | Threshold hit, coding agent is starting repair |
| `🔧 Repair attempt #2 starting...` | Active repair in progress |
| `🚨 Auto-repair failed after 3 attempts` | Rescue mode active — send `/codex` commands |
| `🟢 Gateway recovered` | Back online |

### Rescue mode

When auto-repair is exhausted, reply in Telegram with:

```
/codex inspect gateway.err.log and fix the startup crash
```

The watchdog polls the Telegram Bot API directly (not through OpenClaw), so commands work even while the gateway is down.

---

## Configuration

After install, settings live in `~/.openclaw/watchdog.json`:

```jsonc
{
  "health_url": "http://127.0.0.1:18789", // gateway health endpoint
  "telegram_bot_token_env": "TELEGRAM_BOT_TOKEN_AVA", // env var holding your bot token
  "telegram_chat_id": "123456789", // your Telegram chat ID
  "max_failures": 2, // consecutive failures before repair (2 = ~10 min)
  "cooldown_seconds": 1800, // wait between repair attempts
  "max_repairs_per_incident": 3, // attempts before rescue mode
  "codex_timeout_seconds": 180, // per-attempt timeout
  "rescue_command_timeout_seconds": 420, // timeout for rescue-mode commands
  "rescue_command_prefix": "/codex", // command prefix watched in Telegram
  "recovery_log": "~/.openclaw/workspace/memory/recovery-log.md", // markdown journal
  "state_file": "/tmp/openclaw-watchdog-state", // runtime incident state
  "lock_file": "/tmp/openclaw-watchdog.lock", // overlapping-run lock
  "codex_model": "gpt-5.3-codex", // model for Codex repairs
  "codex_bin": "", // explicit path to codex (auto-detected if empty)
  "claude_bin": "" // explicit path to claude (auto-detected if empty)
}
```

### Common tweaks

- **Faster alerting**: set `"max_failures": 1` to trigger after a single failed check (~5 min)
- **More repair attempts**: bump `"max_repairs_per_incident": 5`
- **Use Claude Code instead of Codex**: install it and leave `codex_bin`/`claude_bin` empty — the watchdog auto-detects whichever is available (prefers Codex, falls back to Claude)

---

## Why Telegram?

The watchdog needs to reach you when OpenClaw is down. WhatsApp, Discord, iMessage, Signal, and Slack traffic normally routes through the OpenClaw gateway — the thing that's broken. This watchdog calls Telegram Bot API directly at `https://api.telegram.org`, so alerts and rescue commands still work during gateway outages.

If you don't use Telegram, the watchdog still auto-repairs. You just won't get alerts.

---

## Gotchas

- **On macOS, the launchd template uses both `StartInterval` and `StartCalendarInterval` (every 5 minutes) for timer reliability.**
- **The bot token goes in your environment**, not in `watchdog.json`. The config stores the *name* of the env var (default: `TELEGRAM_BOT_TOKEN_AVA`). Put the actual token in `~/.openclaw/.env` or your shell profile.
- **Rescue mode only listens to your chat ID.** Other users messaging the bot won't trigger commands.
- **Cooldown is 30 minutes by default.** If a repair fails, the watchdog waits before trying again. This prevents a broken agent from making things worse in a loop.
- **Recovery logs are permanent.** Every repair attempt is logged to `~/.openclaw/workspace/memory/recovery-log.md` so your OpenClaw agent can learn from past incidents.

---

## Uninstall

```bash
# keep config
bash uninstall.sh

# remove config too
bash uninstall.sh --purge
```

Or clone the repo and run `./uninstall.sh` if you used the one-liner install.

---

## 🤖 For Agents

> This section is for OpenClaw agents operating this watchdog autonomously. Humans: you can skip this.

### Install (non-interactive)

```bash
# OpenClaw prerequisite (official installer)
curl -fsSL https://openclaw.ai/install.sh | bash

# Watchdog install
OPENCLAW_WATCHDOG_CHAT_ID="${TELEGRAM_CHAT_ID}" \
  curl -fsSL https://raw.githubusercontent.com/bkochavy/openclaw-watchdog/main/install.sh | bash
```

Verify install:
```bash
bash ~/.openclaw/bin/watchdog.sh  # exit 0 = working, exit 1 = config/dep error
```

### Status checks

```bash
# macOS
launchctl list | grep watchdog

# Linux
systemctl --user status openclaw-watchdog.timer

# Both platforms
STATE_FILE="$(jq -r '.state_file // \"/tmp/openclaw-watchdog-state\"' ~/.openclaw/watchdog.json)"
STATE_FILE="${STATE_FILE/#\~/$HOME}"
cat "$STATE_FILE"                       # current failure count + repair state
tail -50 ~/.openclaw/logs/watchdog.log  # recent activity
```

### Operations

| Action | Command |
|---|---|
| Trigger manual repair cycle | `bash ~/.openclaw/bin/watchdog.sh` |
| Reset incident state | `STATE_FILE="$(jq -r '.state_file // "/tmp/openclaw-watchdog-state"' ~/.openclaw/watchdog.json)"; rm -f "${STATE_FILE/#\~/$HOME}"` |
| Edit thresholds/timeouts | edit `~/.openclaw/watchdog.json` |
| Check if repair is running | `LOCK_FILE="$(jq -r '.lock_file // "/tmp/openclaw-watchdog.lock"' ~/.openclaw/watchdog.json)"; LOCK_FILE="${LOCK_FILE/#\~/$HOME}"; [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null && echo running \|\| echo idle` |
| Send test Telegram alert | `source ~/.openclaw/bin/tg-helper.sh && TOKEN_ENV="$(jq -r '.telegram_bot_token_env // "TELEGRAM_BOT_TOKEN_AVA"' ~/.openclaw/watchdog.json)" && TG_TOKEN="$(printenv "$TOKEN_ENV")" TG_CHAT="<id>" tg_send "test"` |
| Force rescue mode | set `"max_repairs_per_incident": 0` in config, then run watchdog |
| View recovery history | `cat ~/.openclaw/workspace/memory/recovery-log.md` |

### Exit codes

- `0` — normal (healthy, waiting, repairing, rescue polling, or skipped due to lock)
- `1` — config or dependency error (e.g., config exists but `jq` missing)

### File paths

| File | Path |
|---|---|
| Config | `~/.openclaw/watchdog.json` |
| OpenClaw core config | `~/.openclaw/openclaw.json` |
| Main script | `~/.openclaw/bin/watchdog.sh` |
| Telegram helper | `~/.openclaw/bin/tg-helper.sh` |
| Runtime TG helper | `${TMPDIR:-/tmp}/openclaw-tg-helper.sh` |
| Logs | `~/.openclaw/logs/watchdog.log` |
| Repair logs | `~/.openclaw/logs/watchdog-codex-attempt-*.log` |
| Recovery journal | `~/.openclaw/workspace/memory/recovery-log.md` |
| State file | `/tmp/openclaw-watchdog-state` (default, configurable) |
| Lock file | `/tmp/openclaw-watchdog.lock` (default, configurable) |

---

Built for the [OpenClaw](https://openclaw.ai) community. MIT licensed.
