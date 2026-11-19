#!/bin/bash
# Builds a universal release and bundles it with the install, rollback and cleanup scripts:
#   scripts/package.sh           GoldenPassport-<version>.zip
#   scripts/package.sh beta.4    GoldenPassport-<version>-beta.4.zip, a pre-release: the app reports
#                                <version>-beta.4, so its update check offers <version> once released
# SIGN_IDENTITY="Developer ID Application: …" signs the app (default: ad hoc, for testing only).
# NOTARIZE=1 then notarizes and staples it with scripts/notarize.sh (NOTARY_PROFILE picks how).
# Output: $BUILD_ROOT/dist/<name>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/GoldenPassport-build}"
LABEL="${1:-}"
NAME="GoldenPassport-$(cat "$ROOT/VERSION")${LABEL:+-$LABEL}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"
if [ "$NOTARIZE" = 1 ] && [ "$SIGN_IDENTITY" = "-" ]; then
  echo "error: NOTARIZE=1 needs SIGN_IDENTITY=\"Developer ID Application: …\"" >&2; exit 1
fi

ARCHS="arm64 x86_64" BUILD_ROOT="$BUILD_ROOT" PRERELEASE="$LABEL" SIGN_IDENTITY="$SIGN_IDENTITY" \
  "$ROOT/scripts/build-app.sh" release
APP="$BUILD_ROOT/release/GoldenPassport.app"
[ "$NOTARIZE" != 1 ] || "$ROOT/scripts/notarize.sh" "$APP"

STAGE="$BUILD_ROOT/dist/$NAME"
rm -rf "$STAGE" "$STAGE.zip"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/GoldenPassport.app"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/rollback.sh" "$ROOT/scripts/cleanup.sh" "$STAGE/"
cp "$ROOT/docs/install.md" "$STAGE/INSTALL.md"
cp "$ROOT/docs/install.zh-CN.md" "$STAGE/安装说明.md"
cp "$ROOT/LICENSE" "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/rollback.sh" "$STAGE/cleanup.sh"
# No AppleDouble ._ entries: unzip would put them inside the bundle and break its signature.
(cd "$BUILD_ROOT/dist" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$NAME" "$NAME.zip")

echo "Packaged $STAGE.zip"
echo "  signed: $([ "$SIGN_IDENTITY" = - ] && echo "ad hoc (testing only)" || echo "$SIGN_IDENTITY")$([ "$NOTARIZE" = 1 ] && echo ", notarized")"
echo "  sha256: $(shasum -a 256 "$STAGE.zip" | awk '{print $1}')"
