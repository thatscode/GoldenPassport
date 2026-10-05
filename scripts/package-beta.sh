#!/bin/bash
# Builds a universal release and bundles it with the install/rollback scripts
# for testers:  scripts/package-beta.sh [label]   (default label: beta)
# Output: $BUILD_ROOT/dist/GoldenPassport-<version>-<label>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/GoldenPassport-build}"
LABEL="${1:-beta}"
NAME="GoldenPassport-$(cat "$ROOT/VERSION")-$LABEL"

ARCHS="arm64 x86_64" BUILD_ROOT="$BUILD_ROOT" "$ROOT/scripts/build-app.sh" release

STAGE="$BUILD_ROOT/dist/$NAME"
rm -rf "$STAGE" "$STAGE.zip"
mkdir -p "$STAGE"
ditto "$BUILD_ROOT/release/GoldenPassport.app" "$STAGE/GoldenPassport.app"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/rollback.sh" "$STAGE/"
cp "$ROOT/docs/beta-testing.md" "$STAGE/测试说明.md"
chmod +x "$STAGE/install.sh" "$STAGE/rollback.sh"
(cd "$BUILD_ROOT/dist" && ditto -c -k --keepParent "$NAME" "$NAME.zip")

echo "Packaged $STAGE.zip"
echo "  sha256: $(shasum -a 256 "$STAGE.zip" | awk '{print $1}')"
