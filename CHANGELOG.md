## v1.0.2 — 2026-03-07
- Fix: sanitize legacy macOS `ai.openclaw.watchdog.plist` during install/migration by removing stale `StartCalendarInterval` entries
- Prevents duplicate legacy watchdog launches from double-counting failures during migration to sentinel

## v1.0.1 — 2026-02-27
- Fix: harden macOS scheduler by adding `StartCalendarInterval` fallback (every 5 minutes) alongside `StartInterval`
- Improves watchdog trigger reliability when launchd interval-only timers stall

## v1.0.0 — 2026-02-22
- Initial release
- Gateway health check every 5 min (configurable)
- Codex-powered auto-repair after configurable failure threshold
- Live Telegram status updates during repair
- Rescue mode: /codex command prefix for manual intervention
- macOS launchd + Linux systemd support
- Recovery log written to openclaw workspace memory
- Standalone tg-helper.sh for use in other scripts
