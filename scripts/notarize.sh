#!/bin/bash
# Notarizes a Developer ID-signed app and staples the ticket to it, in place:
#   scripts/notarize.sh path/to/GoldenPassport.app
# NOTARY_PROFILE=<name> submits with `xcrun notarytool --keychain-profile <name>`; store the
# profile once with `xcrun notarytool store-credentials <name>` (it asks for the Apple ID, the
# team and an app-specific password, and keeps them in the login Keychain).
# Without NOTARY_PROFILE the Apple ID signed in to Xcode (Settings → Accounts) submits it: the app
# is wrapped in an Xcode archive and uploaded with `xcodebuild -exportArchive`, so no password is
# needed. That account must be a member of the team that signed the app.
set -euo pipefail

APP="${1:?usage: $0 path/to/App.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE")"
grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE" && [ -n "$TEAM_ID" ] \
  || { echo "error: $APP is not signed with a Developer ID Application certificate" >&2; exit 1; }
grep -q 'flags=.*(runtime)' <<<"$SIGNATURE" || { echo "error: $APP lacks the hardened runtime" >&2; exit 1; }
grep -q '^Timestamp=' <<<"$SIGNATURE" || { echo "error: $APP has no secure timestamp" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gp-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Submitting with the notarytool profile \"$NOTARY_PROFILE\"…"
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$WORK/submit.zip"
  xcrun notarytool submit "$WORK/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait \
    | tee "$WORK/submit.log"
  grep -q 'status: Accepted' "$WORK/submit.log" || {
    ID="$(sed -n 's/^ *id: //p' "$WORK/submit.log" | head -1)"
    echo "error: notarization failed; see: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  }
  xcrun stapler staple "$APP"
else
  echo "Submitting with the Apple ID signed in to Xcode (team $TEAM_ID)…"
  INFO="$APP/Contents/Info.plist"
  NAME="$(basename "$APP" .app)"
  ARCHIVE="$WORK/$NAME.xcarchive"
  mkdir -p "$ARCHIVE/Products/Applications"
  ditto "$APP" "$ARCHIVE/Products/Applications/$NAME.app"
  P="$ARCHIVE/Info.plist"
  plutil -create xml1 "$P"
  plutil -insert ArchiveVersion -integer 2 "$P"
  plutil -insert Name -string "$NAME" "$P"
  plutil -insert SchemeName -string "$NAME" "$P"
  plutil -insert CreationDate -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P"
  plutil -insert ApplicationProperties -dictionary "$P"
  plutil -insert ApplicationProperties.ApplicationPath -string "Applications/$NAME.app" "$P"
  plutil -insert ApplicationProperties.Team -string "$TEAM_ID" "$P"
  plutil -insert ApplicationProperties.SigningIdentity \
    -string "$(sed -n 's/^Authority=//p' <<<"$SIGNATURE" | head -1)" "$P"
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    plutil -insert "ApplicationProperties.$key" -string "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO")" "$P"
  done
  cat > "$WORK/options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/options.plist" \
    -exportPath "$WORK/upload" -allowProvisioningUpdates > "$WORK/upload.log" 2>&1 \
    || { tail -20 "$WORK/upload.log" >&2; echo "error: upload failed" >&2; exit 1; }
  echo "Uploaded; waiting for Apple (usually a few minutes)…"
  for _ in $(seq 1 120); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/notarized" \
         > "$WORK/notarized.log" 2>&1; then
      break
    fi
    if ! grep -q 'is processing' "$WORK/notarized.log"; then
      cat "$WORK/notarized.log" >&2; echo "error: notarization failed" >&2; exit 1
    fi
    sleep 30
  done
  [ -d "$WORK/notarized/$NAME.app" ] || { echo "error: timed out waiting for notarization" >&2; exit 1; }
  rm -rf "$APP"
  ditto "$WORK/notarized/$NAME.app" "$APP"
fi

xcrun stapler validate "$APP"
codesign --verify --strict "$APP"
spctl -a -t exec -vv "$APP"
echo "Notarized and stapled $APP"
