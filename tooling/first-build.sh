#!/usr/bin/env bash
#
# First build, on a Mac. Run this before opening Xcode.
#
# It resolves the package, builds the framework alone, then builds the app, and
# writes a compact digest of every error it hit to first-build-errors.txt.
# Nothing in this repository has ever been compiled, so errors on the first run
# are expected; the digest is the thing worth pasting back into Claude.
#
#   ./tooling/first-build.sh
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LOG="$ROOT/.first-build.log"
DIGEST="$ROOT/first-build-errors.txt"
: > "$LOG"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail=0

command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
}

say "Toolchain"
xcodebuild -version | sed 's/^/  /'
swift --version 2>&1 | head -2 | sed 's/^/  /'

say "1/4  Resolving packages"
( cd PencilLoopKit && swift package resolve ) >>"$LOG" 2>&1 \
  && echo "  ok" || { echo "  FAILED - manifest or dependency resolution. See $LOG"; fail=1; }

# Commit this once it exists: it pins swift-markdown so a build is reproducible.
[ -f PencilLoopKit/Package.resolved ] && echo "  Package.resolved present - commit it"

# Xcode synthesises a scheme for a package directory, so this needs no project
# file - which is what makes it a clean isolation of package code from the app.
say "2/4  Building PencilLoopKit for iOS (isolates package code from the app target)"
( cd PencilLoopKit && xcodebuild build \
    -scheme PencilLoopKit \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO ) >>"$LOG" 2>&1 \
  && echo "  ok" || { echo "  errors - digest below"; fail=1; }

say "3/4  Building the app and the share extension"
xcodebuild build \
  -project PencilLoop.xcodeproj \
  -scheme PencilLoop \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  >>"$LOG" 2>&1 && echo "  ok" || { echo "  errors - digest below"; fail=1; }

# Only worth attempting once something compiled; a failed build makes this noise.
if [ "$fail" -eq 0 ]; then
  SIM=$(xcrun simctl list devices available 2>/dev/null \
        | grep -oE 'iPad[^(]*' | head -1 | sed 's/ *$//')
  if [ -n "$SIM" ]; then
    say "4/4  Running the tests on $SIM"
    ( cd PencilLoopKit && xcodebuild test \
        -scheme PencilLoopKit \
        -destination "platform=iOS Simulator,name=$SIM" \
        CODE_SIGNING_ALLOWED=NO ) >>"$LOG" 2>&1 \
      && echo "  ok" || { echo "  test failures - see $LOG"; fail=1; }
  else
    say "4/4  Tests skipped - no iPad simulator installed"
  fi
else
  say "4/4  Tests skipped - nothing compiled yet"
fi

say "Digest"
{
  echo "# first-build errors"
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  $(xcodebuild -version | head -1)"
  echo
  # One line per diagnostic, path made repo-relative, duplicates collapsed.
  grep -E "(error|warning): " "$LOG" \
    | sed "s|$ROOT/||g" \
    | sed 's/^ *//' \
    | sort -u \
    | grep -E "error: " \
    | head -400
  echo
  echo "# counts by file"
  grep -E "error: " "$LOG" | sed "s|$ROOT/||g" | cut -d: -f1 | sort | uniq -c | sort -rn | head -40
} > "$DIGEST"

ERRS=$(grep -cE "error: " "$LOG" || true)
echo "  $ERRS error line(s). Digest: first-build-errors.txt  Full log: .first-build.log"
[ "$ERRS" -gt 0 ] && echo "  Paste first-build-errors.txt back into Claude."
exit $fail
