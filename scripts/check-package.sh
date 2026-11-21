#!/bin/bash
# Checks a zip made by scripts/package.sh: the bundle, the zip's contents and, for builds that keep
# the accounts in accounts.json, a headless data check and installs into temporary folders.
#   scripts/check-package.sh <path>/GoldenPassport-<version>[-<label>].zip
# A release (no label) must be notarized with the ticket stapled, or the in-app update falls back
# to the release page. Builds that keep the accounts in the login Keychain get no data check and
# no install: both would use the real Keychain item, whatever GP_DATA_DIR says.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:?usage: scripts/check-package.sh <path>/GoldenPassport-<version>[-<label>].zip}"
VERSION="$(cat "$ROOT/VERSION")"
NAME="$(basename "$ZIP" .zip)"
fail() { echo "error: $*" >&2; exit 1; }

case "$NAME" in
  "GoldenPassport-$VERSION") LABEL="" ;;
  "GoldenPassport-$VERSION-"*) LABEL="${NAME#GoldenPassport-"$VERSION"-}" ;;
  *) fail "$NAME.zip is not named GoldenPassport-$VERSION[-<label>].zip (VERSION is $VERSION)" ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gp-check.XXXXXX")"
cleanup() {
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  find "$WORK" -name '*.app' -type d -prune -exec "$lsregister" -u {} \; 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== zip"
# AppleDouble ._ entries would end up inside the bundle when extracted with unzip.
if unzip -Z1 "$ZIP" | grep '/\._'; then fail "package contains AppleDouble ._ files"; fi
unzip -q "$ZIP" -d "$WORK/unzipped"
PACKAGE="$WORK/unzipped/$NAME"
[ -d "$PACKAGE" ] || fail "the zip has no top-level folder $NAME/"
for f in GoldenPassport.app install.sh rollback.sh cleanup.sh INSTALL.md 安装说明.md LICENSE; do
  [ -e "$PACKAGE/$f" ] || fail "package lacks $f"
done

echo "== bundle"
APP="$PACKAGE/GoldenPassport.app"
INFO="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null || true; }
codesign --verify --strict "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/GoldenPassport")"
for arch in arm64 x86_64; do [[ " $ARCHS " == *" $arch "* ]] || fail "binary lacks $arch ($ARCHS)"; done
for f in en.lproj/Localizable.strings en.lproj/Localizable.stringsdict zh-Hans.lproj/Localizable.strings LICENSE; do
  [ -f "$APP/Contents/Resources/$f" ] || fail "bundle lacks Resources/$f"
done
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "bundle version $(plist CFBundleShortVersionString) is not $VERSION"
# Pre-releases report <version>-<label>, so the update check offers the release.
[ "$(plist GPPrerelease)" = "$LABEL" ] || fail "GPPrerelease is '$(plist GPPrerelease)', expected '$LABEL'"

if [ -z "$LABEL" ]; then
  echo "== notarization"
  spctl --assess --type execute "$APP" || fail "Gatekeeper rejects the app: a release must be notarized"
  xcrun stapler validate -q "$APP" || fail "no stapled notarization ticket"
fi

if [ -n "$(plist GPKeychainService)" ]; then
  echo "== data check and install: skipped (accounts in the login Keychain)"
  echo "Package OK: $NAME.zip"
  exit 0
fi

echo "== data check"
"$APP/Contents/MacOS/GoldenPassport" --migrate-data --data-dir "$WORK/gp-data"

echo "== install"
export GP_APPLICATIONS_DIR="$WORK/apps" GP_DATA_DIR="$WORK/install-data" \
  GP_BACKUP_ROOT="$WORK/backups" GP_NO_LAUNCH=1 GP_LANG=en
mkdir -p "$GP_APPLICATIONS_DIR"
bash "$PACKAGE/install.sh"
FIRST="$(ls -d "$GP_BACKUP_ROOT"/*/)"
MANIFEST="$(shasum "$FIRST/manifest.txt")"
# A second install in the same second must not reuse, and overwrite, that backup.
mkdir "$WORK/clock"
printf '#!/bin/bash\n[ "$1" = "+%%Y%%m%%d-%%H%%M%%S" ] && exec echo %s\nexec /bin/date "$@"\n' \
  "$(basename "$FIRST")" > "$WORK/clock/date"
chmod +x "$WORK/clock/date"
if PATH="$WORK/clock:$PATH" bash "$PACKAGE/install.sh" > "$WORK/second.log" 2>&1; then
  cat "$WORK/second.log"; fail "install.sh reused an existing backup folder"
fi
grep -q 'Could not create a new backup folder' "$WORK/second.log" || { cat "$WORK/second.log"; fail "unexpected output from the second install"; }
[ "$(shasum "$FIRST/manifest.txt")" = "$MANIFEST" ] || fail "the second install changed the first backup"
# With the real clock, the next install gets a backup folder of its own.
bash "$PACKAGE/install.sh"
[ "$(ls -d "$GP_BACKUP_ROOT"/*/ | wc -l | tr -d ' ')" -eq 2 ] || fail "expected two backup folders"

echo "Package OK: $NAME.zip"
