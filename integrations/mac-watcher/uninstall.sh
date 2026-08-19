#!/bin/bash
# Remove the launchd agent. Leaves ~/.pencil-loop (config, ledger, logs) alone
# unless --purge is passed.
set -euo pipefail

LABEL="co.pencil-loop.watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "removed $LABEL"

if [ "${1:-}" = "--purge" ]; then
  rm -f "$HOME/.pencil-loop/watcher-ledger.json"
  rm -rf "$HOME/.pencil-loop/logs"
  echo "purged the ledger and logs (config.json kept)"
  echo "NOTE: with the ledger gone, every bundle still in outbox/ will be treated"
  echo "      as new and delivered again the next time the watcher runs."
fi
