#!/bin/bash
set -euo pipefail
UID_NUM="$(id -u)"
PLIST="${HOME}/Library/LaunchAgents/com.dawnhaul.sync.plist"
launchctl bootout "gui/${UID_NUM}/com.dawnhaul.sync" 2>/dev/null || true
rm -f "${PLIST}"
echo "Launch agent removed. ~/Dawnhaul was left in place (logs + staging)."
echo "Delete it with:  rm -rf ~/Dawnhaul"

