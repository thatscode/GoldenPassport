#!/bin/bash
# Installs (or upgrades to) GoldenPassport 0.2.x over an existing installation.
#
#   bash install.sh [GoldenPassport.app | GoldenPassport-*.zip]
#
# Steps: check the package -> back up the installed app and data directory ->
# quit the running app -> replace /Applications/GoldenPassport.app -> migrate and
# verify data (names only, never secrets) -> launch. If migration does not verify,
# the previous app and data are restored automatically. Builds that keep the accounts in
# the login Keychain (Info.plist GPKeychainService) move them there from accounts.json or
# gp.secrets; the backup holds the data folder only, and a Keychain item a failed migration
# wrote stays and is set aside by the next one (docs/design/d3-keychain.md 5.4).
#
# WARNING: the backup in ~/GoldenPassport-backups/ is an UNENCRYPTED copy of every
# MFA secret. It is made owner-only (chmod go-rwx); users must delete it once they
# no longer need to roll back.
#
# Messages are in Simplified Chinese or English, like the app (see ui_language).
# Environment overrides (for testing): GP_APPLICATIONS_DIR, GP_DATA_DIR,
# GP_BACKUP_ROOT, GP_NO_LAUNCH=1, GP_LANG=zh-Hans|en.
set -euo pipefail

# 0.2.1 moved the bundle id; 0.1.x and 0.2.0 used the old one.
BUNDLE_ID="com.thatscode.GoldenPassport"
LEGACY_BUNDLE_ID="site.stanzhai.GoldenPassport"
APPS_DIR="${GP_APPLICATIONS_DIR:-/Applications}"
DATA_DIR="${GP_DATA_DIR:-$HOME/Library/Application Support/GoldenPassport}"
BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"
TARGET="$APPS_DIR/GoldenPassport.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The app's own language setting (menu: 语言 / Language), else the system's preferred
# languages, matched by macOS exactly as it does for the app. 0.1.x and 0.2.0 kept the setting
# under the old bundle id; 0.2.1 carries it over once (GPLegacyPreferencesCarriedOver).
ui_language() {
  osascript -l JavaScript -e '
    ObjC.import("Foundation");
    function run(argv) {
      var defaults = $.NSUserDefaults.standardUserDefaults, languages;
      for (var i = 0; i < argv.length; i++) {
        var domain = ObjC.deepUnwrap(defaults.persistentDomainForName(argv[i])) || {};
        if (domain.AppleLanguages) { languages = $(domain.AppleLanguages); break; }
        if (domain.GPLegacyPreferencesCarriedOver) break;
      }
      if (!languages) languages = defaults.objectForKey("AppleLanguages");
      return ObjC.unwrap($.NSBundle.preferredLocalizationsFromArrayForPreferences($(["en", "zh-Hans"]), languages).firstObject);
    }' "$BUNDLE_ID" "$LEGACY_BUNDLE_ID" 2>/dev/null || echo en
}
UI_LANG="${GP_LANG:-$(ui_language)}"
# say ZH EN prints the message in the UI language; a single argument is printed as is.
say() { if [ $# -eq 1 ] || [ "$UI_LANG" = zh-Hans ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi; }

step() { printf '\n==> %s\n' "$(say "$@")"; }
info() { printf '    %s\n' "$(say "$@")"; }
die() { printf '\n%s %s\n' "$(say '[失败]' '[FAILED]')" "$(say "$@")" >&2; exit 1; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

describe_app() {
  local app="$1" label
  [ -d "$app" ] || { say "未安装" "not installed"; return; }
  if [ -n "$(plist_value "$app" GPDataDirectoryName)" ]; then
    label="$(plist_value "$app" GPPrerelease)"   # beta packages, e.g. 0.2.0-beta.3
    echo "$(plist_value "$app" CFBundleShortVersionString)${label:+-$label} (build $(plist_value "$app" CFBundleVersion))"
  else
    say "0.1.x 旧版" "0.1.x"
  fi
}

# The GoldenPassport processes to quit: the one running from $1 and, when installing into the real
# /Applications, every other copy too (one opened from the download folder, for example), which
# would otherwise keep running next to the new version. A test install only touches its own app.
app_pids() {
  { pgrep -f "^$1/Contents/MacOS/" || true
    [ "$APPS_DIR" != /Applications ] || pgrep -x GoldenPassport || true; } | sort -u
}

quit_app() {
  local app="$1" pids i
  pids="$(app_pids "$app")"
  [ -n "$pids" ] || return 0
  info "正在退出运行中的 GoldenPassport (pid $(echo $pids))" "Quitting the running GoldenPassport (pid $(echo $pids))"
  kill -TERM $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(app_pids "$app")" ] || return 0
    sleep 0.5
  done
  kill -KILL $pids 2>/dev/null || true
  sleep 0.5
}

checksum() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "none"; }

# --- 1. Package -------------------------------------------------------------
step "检查安装包" "Checking the package"
SOURCE="${1:-$SCRIPT_DIR/GoldenPassport.app}"
WORK="$(mktemp -d -t gp-install)"
trap 'rm -rf "$WORK"' EXIT
case "$SOURCE" in
  *.zip)
    ditto -x -k "$SOURCE" "$WORK/unzipped"
    SOURCE="$(find "$WORK/unzipped" -maxdepth 2 -name GoldenPassport.app -type d | head -n 1)"
    [ -n "$SOURCE" ] || die "压缩包里没有 GoldenPassport.app" "The zip file has no GoldenPassport.app in it" ;;
esac
[ -d "$SOURCE" ] || die "找不到安装包：$SOURCE" "Package not found: $SOURCE"
SOURCE="$(cd "$SOURCE" && pwd)"
[ "$SOURCE" != "$TARGET" ] || die "安装包就是已安装的 App，请指定新下载的 GoldenPassport.app" \
  "That is the installed app itself. Point to the GoldenPassport.app you downloaded"

case "$(plist_value "$SOURCE" CFBundleIdentifier)" in "$BUNDLE_ID"|"$LEGACY_BUNDLE_ID") ;; *) false ;; esac \
  || die "不是 GoldenPassport 正式版安装包（Bundle ID 不符）" "Not a GoldenPassport release package (wrong bundle ID)"
[ -n "$(plist_value "$SOURCE" GPDataDirectoryName)" ] \
  || die "这是 0.1.x 旧版安装包，回退请用 rollback.sh" "This is a 0.1.x package. To go back to 0.1.x, use rollback.sh"
codesign --verify --strict "$SOURCE" 2>/dev/null \
  || die "安装包签名校验失败，可能已损坏，请重新下载" "The package's signature does not verify. It may be damaged; download it again"

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 13 ] || die "需要 macOS 13 或更高版本，当前是 $(sw_vers -productVersion)" \
  "macOS 13 or later is required; this Mac has $(sw_vers -productVersion)"
ARCH="$(uname -m)"
lipo -archs "$SOURCE/Contents/MacOS/GoldenPassport" | tr ' ' '\n' | grep -qx "$ARCH" \
  || die "安装包不支持这台 Mac 的架构 ($ARCH)，请使用通用版 (Universal) 安装包" \
    "The package does not support this Mac's architecture ($ARCH). Use the universal package"

NEW_VERSION="$(describe_app "$SOURCE")"
OLD_VERSION="$(describe_app "$TARGET")"
info "新版本：$NEW_VERSION" "New version: $NEW_VERSION"
info "当前已安装：$OLD_VERSION" "Installed now: $OLD_VERSION"
info "数据目录：$DATA_DIR" "Data folder: $DATA_DIR"

# --- 2. Backup --------------------------------------------------------------
step "备份当前的 App 和数据" "Backing up the current app and data"
# A new folder for every run, named by the time so rollback.sh can pick the newest. mkdir
# without -p fails if the folder exists, so a second run in the same second waits for the
# next one instead of writing over the first run's backup.
mkdir -p "$BACKUP_ROOT" 2>/dev/null || true
BACKUP=""
for attempt in 1 2 3; do
  candidate="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  if mkdir "$candidate" 2>/dev/null; then BACKUP="$candidate"; break; fi
  sleep 1
done
[ -n "$BACKUP" ] || die "无法在 ${BACKUP_ROOT} 里新建备份目录，没有做任何改动" \
  "Could not create a new backup folder in $BACKUP_ROOT. Nothing was changed"
chmod 700 "$BACKUP_ROOT" "$BACKUP"
if [ -d "$TARGET" ]; then
  # A zip, not a second .app: two bundles with the same id confuse Launch Services.
  ditto -c -k --keepParent "$TARGET" "$BACKUP/GoldenPassport.app.zip"
  info "App → $BACKUP/GoldenPassport.app.zip"
fi
if [ -d "$DATA_DIR" ]; then
  ditto "$DATA_DIR" "$BACKUP/data"
  info "数据 → $BACKUP/data" "Data → $BACKUP/data"
fi
chmod -R go-rwx "$BACKUP"
info "⚠️  备份里有你全部 MFA 密钥的未加密副本（权限：仅本人可读）" \
  "⚠️  The backup holds an unencrypted copy of all your MFA secrets (readable only by you)"
{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "previous_version=$OLD_VERSION"
  echo "installed_version=$NEW_VERSION"
  echo "apps_dir=$APPS_DIR"
  echo "data_dir=$DATA_DIR"
  echo "had_app=$([ -d "$TARGET" ] && echo yes || echo no)"
  echo "had_data=$([ -d "$DATA_DIR" ] && echo yes || echo no)"
  echo "gp_secrets_sha256=$(checksum "$DATA_DIR/gp.secrets")"
  echo "accounts_json_sha256=$(checksum "$DATA_DIR/accounts.json")"
} > "$BACKUP/manifest.txt"

restore_previous() {
  step "正在恢复安装前的状态" "Restoring the state before the install"
  quit_app "$TARGET"
  rm -rf "$TARGET"
  if [ -f "$BACKUP/GoldenPassport.app.zip" ]; then
    ditto -x -k "$BACKUP/GoldenPassport.app.zip" "$APPS_DIR"
  fi
  rm -rf "$DATA_DIR"
  if [ -d "$BACKUP/data" ]; then
    ditto "$BACKUP/data" "$DATA_DIR"
  fi
  info "已恢复。备份保留在 $BACKUP" "Restored. The backup stays in $BACKUP"
}

# --- 3. Replace -------------------------------------------------------------
step "安装新版本" "Installing the new version"
quit_app "$TARGET"
STAGED="$APPS_DIR/.GoldenPassport.app.installing"
rm -rf "$STAGED"
ditto "$SOURCE" "$STAGED" || die "无法写入 ${APPS_DIR}，请确认当前账号有管理员权限" \
  "Cannot write to ${APPS_DIR}. Make sure your macOS account is an administrator"
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true
rm -rf "$TARGET"
mv "$STAGED" "$TARGET"
info "已安装到 $TARGET" "Installed to $TARGET"

# --- 4. Migrate & verify ----------------------------------------------------
step "迁移并核对数据" "Migrating and checking your data"
set +e
REPORT="$("$TARGET/Contents/MacOS/GoldenPassport" --migrate-data --data-dir "$DATA_DIR" 2>&1)"
STATUS=$?
set -e
report_value() { printf '%s\n' "$REPORT" | sed -n "s/^$1=//p" | head -n 1; }
if [ $STATUS -ne 0 ]; then
  printf '%s\n' "$REPORT" | sed 's/^/    /'
  restore_previous
  die "数据核对没有通过，已自动恢复到安装前的状态。请到 https://github.com/thatscode/GoldenPassport/issues 反馈，并附上上面的输出（里面只有账号名称，没有密钥）。" \
    "The data check failed, so the previous state was restored. Please report this at https://github.com/thatscode/GoldenPassport/issues and include the output above (it shows account names only, no secrets)."
fi
ACCOUNTS="$(report_value account_count)"
STORAGE="$(report_value storage)"
SOURCE_FILE="$(report_value source)"
case "$(report_value status):$STORAGE:$SOURCE_FILE" in
  migrated:keychain:accounts.json) info "已把 $ACCOUNTS 条记录从 accounts.json 迁移到登录钥匙串，逐条一致" \
    "Moved $(plural "$ACCOUNTS" account accounts) from accounts.json into the login keychain; every entry matches" ;;
  migrated:keychain:*) info "已从旧版迁移 $ACCOUNTS 条记录到登录钥匙串，与 gp.secrets 的 $(report_value legacy_count) 条逐条一致" \
    "Moved $(plural "$ACCOUNTS" account accounts) from 0.1.x into the login keychain; every entry matches gp.secrets" ;;
  migrated:*) info "已从旧版迁移 $ACCOUNTS 条记录，与 gp.secrets 的 $(report_value legacy_count) 条逐条一致" \
    "Migrated $(plural "$ACCOUNTS" account accounts) from 0.1.x; every entry matches gp.secrets" ;;
  already-migrated:*) info "沿用已有数据：$ACCOUNTS 条记录" "Keeping your existing data: $(plural "$ACCOUNTS" account accounts)" ;;
  no-data:*) info "没有发现旧数据，这是一次全新安装" "No existing data found; this is a fresh install" ;;
esac
manifest_value() { sed -n "s/^$1=//p" "$BACKUP/manifest.txt" | head -n 1; }
[ "$(checksum "$DATA_DIR/gp.secrets")" = "$(manifest_value gp_secrets_sha256)" ] \
  || { restore_previous; die "gp.secrets 在安装过程中发生了变化，已自动恢复" "gp.secrets changed during the install, so the previous state was restored"; }
# A build without the Keychain writes accounts.json itself; one with it must leave the file alone.
[ "$STORAGE" != keychain ] || [ "$(checksum "$DATA_DIR/accounts.json")" = "$(manifest_value accounts_json_sha256)" ] \
  || { restore_previous; die "accounts.json 在安装过程中发生了变化，已自动恢复" "accounts.json changed during the install, so the previous state was restored"; }
if [ -f "$DATA_DIR/gp.secrets" ]; then
  info "旧版数据文件 gp.secrets 未被改动，可随时回退" "The 0.1.x data file gp.secrets is unchanged, so you can roll back at any time"
fi
if [ "$STORAGE" = keychain ] && [ -f "$DATA_DIR/accounts.json" ]; then
  info "内测版的数据文件 accounts.json 未被改动，可随时回退" "The beta's data file accounts.json is unchanged, so you can roll back at any time"
fi
# Unencrypted files that stay in the data folder for rolling back, for the warning below.
LEFT_ZH=""; LEFT_EN=""
for name in gp.secrets accounts.json; do
  [ -f "$DATA_DIR/$name" ] || continue
  [ "$name" = gp.secrets ] || [ "$STORAGE" = keychain ] || continue
  LEFT_ZH="${LEFT_ZH:+$LEFT_ZH 和 }$name"; LEFT_EN="${LEFT_EN:+$LEFT_EN and }$name"
done

# Accounts 0.1.x changed after the migration, e.g. after rollback.sh (names only).
LEGACY_CHANGES="$(printf '%s\n' "$REPORT" | sed -n 's/^legacy_change=//p')"
if [ -n "$LEGACY_CHANGES" ]; then
  COUNT="$(printf '%s\n' "$LEGACY_CHANGES" | wc -l | tr -d ' ')"
  info "回退期间，0.1.x 改动了 $COUNT 个账号，GoldenPassport 启动后会提示你处理：" \
    "While you were back on 0.1.x, it changed $(plural "$COUNT" account accounts). GoldenPassport will ask you about them when it starts:"
  printf '%s\n' "$LEGACY_CHANGES" | while IFS= read -r change; do
    case "${change%%:*}" in
      added) info "  • 新增：${change#*:}" "  • added: ${change#*:}" ;;
      changed) info "  • 改过：${change#*:}" "  • changed: ${change#*:}" ;;
      *) info "  • 删除：${change#*:}" "  • deleted: ${change#*:}" ;;
    esac
  done
fi

# --- 5. Launch --------------------------------------------------------------
if [ "${GP_NO_LAUNCH:-0}" != "1" ]; then
  step "启动 GoldenPassport" "Starting GoldenPassport"
  open "$TARGET"
fi

KEYCHAIN_NOTE=""; LEFT_NOTE=""
if [ "$UI_LANG" = zh-Hans ]; then
[ "$STORAGE" != keychain ] || KEYCHAIN_NOTE="  • 账号现在保存在登录钥匙串里（「钥匙串访问」中名为 GoldenPassport 的条目），
    数据目录里不再写入密钥。
"
[ -z "$LEFT_ZH" ] || LEFT_NOTE="  • 数据目录里的 $LEFT_ZH 也是明文，会一直保留（供回退使用），
    其中包括你之后在新版里删除的记录。
"
cat <<EOF

安装完成：$OLD_VERSION → $NEW_VERSION

注意事项
  • 全局快捷键默认是 ⌃⌥⌘0–9（旧版是 ⇧⌘0–9），可在菜单「全局快捷键」里切换。
  • 自动填入验证码需要重新授权「辅助功能」：系统设置 → 隐私与安全性 → 辅助功能。
    如果列表里已有 GoldenPassport 但不生效，先用「−」删掉，再在菜单里重新选一次快捷键。
  • 回退到安装前的版本：bash "$SCRIPT_DIR/rollback.sh"
$KEYCHAIN_NOTE
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ⚠️  重要：备份中含有全部 MFA 密钥的未加密副本
      $BACKUP
  • 拿到这个目录的人可以生成你所有账号的验证码。
  • 不要复制、上传、发给别人，也不要放进 iCloud / 网盘等同步目录。
${LEFT_NOTE}  • 确认新版使用正常、不再需要回退后，运行清理脚本把它们都删掉：
      bash "$SCRIPT_DIR/cleanup.sh"
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
else
[ "$STORAGE" != keychain ] || KEYCHAIN_NOTE="  • Your accounts are now in the login keychain (the item named GoldenPassport in
    Keychain Access); the data folder no longer holds any secrets.
"
[ -z "$LEFT_EN" ] || LEFT_NOTE="  • The data folder also keeps $LEFT_EN unencrypted (for rolling
    back), including accounts you delete later in the new version.
"
cat <<EOF

Installed: $OLD_VERSION → $NEW_VERSION

Good to know
  • Global hotkeys now default to ⌃⌥⌘0–9 (0.1.x used ⇧⌘0–9); change them under Global Hotkeys in the menu.
  • To have hotkeys type the code for you, grant Accessibility again:
    System Settings → Privacy & Security → Accessibility. If GoldenPassport is already listed
    but typing doesn't work, remove it with "−" and pick a hotkey option in the menu again.
  • To go back to the version you had before: bash "$SCRIPT_DIR/rollback.sh"
$KEYCHAIN_NOTE
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ⚠️  IMPORTANT: the backup holds an unencrypted copy of all your MFA secrets
      $BACKUP
  • Anyone who gets this folder can generate codes for all your accounts.
  • Don't copy, upload or send it to anyone, and keep it out of iCloud and
    other synced folders.
${LEFT_NOTE}  • Once the new version works for you and you no longer need to roll back,
    delete all of it with the cleanup script:
      bash "$SCRIPT_DIR/cleanup.sh"
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
fi
