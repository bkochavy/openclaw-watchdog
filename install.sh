#!/usr/bin/env bash
set -euo pipefail

printf "%s\n" "openclaw-watchdog is deprecated and is no longer recommended for current OpenClaw installs." >&2
printf "%s\n" "Use a single sentinel-style recovery path instead of overlapping watchdog layers." >&2
printf "%s\n" "No changes were made." >&2
exit 1
