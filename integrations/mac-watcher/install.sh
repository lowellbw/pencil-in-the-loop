#!/bin/bash
# Install the Pencil-in-the-loop outbox watcher as a launchd user agent.
#
#   ./install.sh
#
# Idempotent: re-running replaces the agent with an up-to-date one.
set -euo pipefail

LABEL="co.pencil-loop.watcher"
WATCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
CONFIG="$HOME/.pencil-loop/config.json"
LOG_DIR="$HOME/.pencil-loop/logs"

PYTHON="${PYTHON:-$(command -v python3 || true)}"
if [ -z "$PYTHON" ]; then
  echo "error: python3 not found. Install it, or set PYTHON=/path/to/python3" >&2
  exit 1
fi

"$PYTHON" - <<'PY' || { echo "error: Python 3.9 or newer is required" >&2; exit 1; }
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY

if [ ! -f "$CONFIG" ]; then
  echo "note: $CONFIG does not exist yet."
  echo "      Create it (see config.example.json) with a \"syncRoot\" pointing at your"
  echo "      sync folder before the watcher can do anything. The agent will keep"
  echo "      running and will pick it up once it appears."
fi

mkdir -p "$AGENT_DIR" "$LOG_DIR"

sed \
  -e "s|__PYTHON__|$PYTHON|g" \
  -e "s|__WATCHER_DIR__|$WATCHER_DIR|g" \
  -e "s|__LOG_DIR__|$LOG_DIR|g" \
  -e "s|__HOME__|$HOME|g" \
  "$WATCHER_DIR/launchd/$LABEL.plist" > "$PLIST"

# bootout first so a re-install replaces rather than duplicates.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

echo "installed $LABEL"
echo "  plist:  $PLIST"
echo "  python: $PYTHON"
echo "  logs:   $LOG_DIR/watcher.log"
echo
echo "Check it is alive:   launchctl print gui/$UID/$LABEL | head -20"
echo "Watch the log:       tail -f $LOG_DIR/watcher.log"
echo "Uninstall:           ./uninstall.sh"
