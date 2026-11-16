#!/bin/bash
# Assembles GoldenPassport.app from the Swift package.
#   scripts/build-app.sh dev       isolated build: own bundle id, data dir, port; hotkeys off
#   scripts/build-app.sh release   drop-in replacement for the installed app
# ARCHS="arm64 x86_64" builds a universal binary (default: arm64).
# PRERELEASE=beta.3 marks a pre-release: the app then reports 0.2.0-beta.3, so its update
# check offers 0.2.0 itself (Info.plist GPPrerelease; CFBundleShortVersionString stays 0.2.0).
# SIGN_IDENTITY="Developer ID Application: …" signs with that identity; the default "-" signs ad hoc.
# KEYCHAIN=1 keeps the accounts in the login Keychain (Info.plist GPKeychainService, data format 2,
# docs/design/d3-keychain.md), KEYCHAIN=0 in accounts.json. The default is 1 only with a signing
# identity: macOS treats every ad-hoc build as a new app and would ask for Keychain access after
# each update.
set -euo pipefail

VARIANT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/GoldenPassport-build}"
ARCHS="${ARCHS:-arm64}"
PRERELEASE="${PRERELEASE:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then KEYCHAIN="${KEYCHAIN:-0}"; else KEYCHAIN="${KEYCHAIN:-1}"; fi
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

case "$VARIANT" in
  dev)
    APP_NAME="GoldenPassport Dev"; EXECUTABLE="GoldenPassport Dev"; BUNDLE_ID="site.stanzhai.GoldenPassport.dev"
    DATA_DIR="GoldenPassport-Dev"; SEED_DIR="GoldenPassport"; PORT=17305; HOTKEYS=false ;;
  release)
    APP_NAME="GoldenPassport"; EXECUTABLE="GoldenPassport"; BUNDLE_ID="site.stanzhai.GoldenPassport"
    DATA_DIR="GoldenPassport"; SEED_DIR=""; PORT=17304; HOTKEYS=true ;;
  *) echo "usage: $0 dev|release" >&2; exit 1 ;;
esac

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
SCRATCH="$BUILD_ROOT/swiftpm"
xcrun swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" "${ARCH_FLAGS[@]}"
BIN_DIR="$(xcrun swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="$BUILD_ROOT/$VARIANT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GoldenPassport" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/statusIcon.png" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/"

# UI strings are written in Simplified Chinese and used as localization keys;
# en.lproj/Localizable.strings translates them (Localizable.stringsdict those with a count)
# and zh-Hans.lproj maps each key to itself (otherwise Chinese lookups fall through to en).
# Other languages fall back to en.
# The .lproj folders also matter for Bartender 7: without them AppKit ran in zh_CN
# and the status item's Chinese AXRoleDescription made Bartender ignore it.
for lproj in en zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$lproj.lproj"
  printf '"CFBundleName" = "%s";\n' "$APP_NAME" > "$APP/Contents/Resources/$lproj.lproj/InfoPlist.strings"
done
for lproj in en zh-Hans; do
  cp "$ROOT/Resources/$lproj.lproj/"Localizable.* "$APP/Contents/Resources/$lproj.lproj/"
done

ICONSET="$BUILD_ROOT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 128 256; do
  sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$EXECUTABLE</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2017 StanZhai, 2026 thatscode and contributors. MIT License.</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>GPDataDirectoryName</key><string>$DATA_DIR</string>
	<key>GPSeedDirectoryName</key><string>$SEED_DIR</string>
	<key>GPDefaultHTTPPort</key><integer>$PORT</integer>
	<key>GPHotkeysEnabledByDefault</key><$HOTKEYS/>
</dict>
</plist>
PLIST
[ -z "$PRERELEASE" ] || /usr/libexec/PlistBuddy -c "Add :GPPrerelease string $PRERELEASE" "$APP/Contents/Info.plist"
# The Dev build keeps its own Keychain item, as it keeps its own data folder.
[ "$KEYCHAIN" != 1 ] || /usr/libexec/PlistBuddy -c "Add :GPKeychainService string $BUNDLE_ID" "$APP/Contents/Info.plist"

xattr -cr "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --options runtime --timestamp=none --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP"
echo "  archs: $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")  version: $VERSION${PRERELEASE:+-$PRERELEASE} ($BUILD_NUMBER)  bundle id: $BUNDLE_ID"
echo "  accounts: $([ "$KEYCHAIN" = 1 ] && echo "login Keychain ($BUNDLE_ID)" || echo accounts.json)  signed: $([ "$SIGN_IDENTITY" = - ] && echo ad hoc || echo "$SIGN_IDENTITY")"
