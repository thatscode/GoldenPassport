#!/bin/bash
# What CI runs, on this Mac: the shell scripts' syntax, the unit tests, and a universal pre-release
# package built, checked and installed into temporary folders (scripts/check-package.sh).
# Run it before every release; the release doesn't wait for CI.
# The tests also run with Xcode 16.0, the oldest supported toolchain, when it is installed
# (OLDEST_XCODE, default /Applications/Xcode_16.0.app).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/GoldenPassport-build}"
OLDEST_XCODE="${OLDEST_XCODE:-/Applications/Xcode_16.0.app}"
cd "$ROOT"

echo "== shell scripts"
for f in scripts/*.sh; do bash -n "$f"; done

echo "== unit tests ($(xcrun swift --version 2>/dev/null | grep -o 'Swift version [0-9.]*'))"
make test BUILD_ROOT="$BUILD_ROOT"

NOT_COVERED=""
if [ -d "$OLDEST_XCODE/Contents/Developer" ]; then
  echo "== unit tests ($OLDEST_XCODE)"
  # A scratch folder of its own: the two compilers can't share build products.
  DEVELOPER_DIR="$OLDEST_XCODE/Contents/Developer" make test BUILD_ROOT="$BUILD_ROOT/oldest-xcode"
else
  NOT_COVERED="Xcode 16.0 (not installed at $OLDEST_XCODE): newer Swift could break building from source with it"
fi

echo "== pre-release package"
# Its own build folder, so the packages in $BUILD_ROOT/dist stay as they are.
CHECK_ROOT="$BUILD_ROOT/check"
make beta BUILD_ROOT="$CHECK_ROOT"
scripts/check-package.sh "$CHECK_ROOT/dist/GoldenPassport-$(cat VERSION)-beta.zip"

echo
echo "All checks passed."
[ -z "$NOT_COVERED" ] || echo "Not covered: $NOT_COVERED"
