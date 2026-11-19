#!/bin/bash
# Restores the GoldenPassport app that install.sh replaced.
#
#   bash rollback.sh [--restore-data] [backup-dir]
#
# By default only the app is restored and the data stays as it is: 0.2.x never
# writes the gp.secrets that 0.1.x reads, and an earlier 0.2.x build reads the same
# accounts.json. Once the accounts are in the login Keychain (accounts-v2.json in the
# data directory), a restored build that doesn't use the Keychain sees accounts.json or
# gp.secrets as they were at the move; the script says so (I5). --restore-data also
# resets the whole data directory to its pre-install state, discarding changes made
# since the install; the Keychain item stays, and the next install sets it aside.
#
# Messages are in Simplified Chinese or English, like the app (see ui_language).
# Environment overrides (for testing): GP_BACKUP_ROOT, GP_NO_LAUNCH=1, GP_LANG=zh-Hans|en.
set -euo pipefail

# 0.2.1 moved the bundle id; 0.1.x and 0.2.0 used the old one.
BUNDLE_ID="com.thatscode.GoldenPassport"
LEGACY_BUNDLE_ID="site.stanzhai.GoldenPassport"
BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"

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

usage() {
  say "用法：bash rollback.sh [--restore-data] [备份目录]

恢复 install.sh 替换掉的 GoldenPassport。默认只恢复 App，数据保持不变：0.1.x 读取的
gp.secrets 从未被 0.2.x 改动过，更早的 0.2.x 版本读取的是同一个 accounts.json。
账号已经存进钥匙串时，不用钥匙串的旧版本只能看到迁移那一刻的数据，脚本会提醒你。
加上 --restore-data 会把整个数据目录也恢复到安装前，安装之后做的改动会丢失。
不指定备份目录时，使用 $BACKUP_ROOT 里最新的一份。
" "Usage: bash rollback.sh [--restore-data] [backup-folder]

Restores the GoldenPassport app that install.sh replaced. By default only the app
is restored and your data stays as it is: 0.2.x never writes the gp.secrets that
0.1.x reads, and an earlier 0.2.x build reads the same accounts.json. Once your
accounts are in the keychain, an older version that doesn't use it only sees the
data from the time they moved; the script tells you so.
--restore-data also resets the whole data folder to its state before the install,
discarding changes made since then. Without a backup folder, the newest one in
$BACKUP_ROOT is used.
"
}

RESTORE_DATA=0
BACKUP=""
for arg in "$@"; do
  case "$arg" in
    --restore-data) RESTORE_DATA=1 ;;
    -h|--help) usage; exit 0 ;;
    *) BACKUP="$arg" ;;
  esac
done

step() { printf '\n==> %s\n' "$(say "$@")"; }
info() { printf '    %s\n' "$(say "$@")"; }
die() { printf '\n%s %s\n' "$(say '[失败]' '[FAILED]')" "$(say "$@")" >&2; exit 1; }
checksum() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "none"; }

if [ -z "$BACKUP" ]; then
  BACKUP="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n 1 || true)"
  [ -n "$BACKUP" ] || die "在 $BACKUP_ROOT 下没有找到备份" "No backups found in $BACKUP_ROOT"
fi
BACKUP="${BACKUP%/}"
MANIFEST="$BACKUP/manifest.txt"
[ -f "$MANIFEST" ] || die "$BACKUP 不是 install.sh 生成的备份（缺少 manifest.txt）" \
  "$BACKUP is not a backup made by install.sh (manifest.txt is missing)"
manifest() { sed -n "s/^$1=//p" "$MANIFEST" | head -n 1; }

APPS_DIR="$(manifest apps_dir)"
DATA_DIR="$(manifest data_dir)"
TARGET="$APPS_DIR/GoldenPassport.app"

step "回退计划" "Rollback plan"
info "备份：${BACKUP}（$(manifest date)）" "Backup: $BACKUP ($(manifest date))"
info "当前：$(manifest installed_version) → 回退到：$(manifest previous_version)" \
  "Now: $(manifest installed_version) → going back to: $(manifest previous_version)"
if [ $RESTORE_DATA = 1 ]; then
  info "数据：整个数据目录恢复到安装前（安装之后做的改动会丢失）" \
    "Data: the whole data folder goes back to its state before the install (changes made since then are lost)"
else
  info "数据：保持不变" "Data: left as it is"
fi

step "退出 GoldenPassport" "Quitting GoldenPassport"
# The copy in $TARGET and, for the real /Applications, every other running copy (one opened from
# the download folder, for example), so that only the restored app runs afterwards.
app_pids() {
  { pgrep -f "^$TARGET/Contents/MacOS/" || true
    [ "$APPS_DIR" != /Applications ] || pgrep -x GoldenPassport || true; } | sort -u
}
pids="$(app_pids)"
if [ -n "$pids" ]; then
  kill -TERM $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(app_pids)" ] || break
    sleep 0.5
  done
  kill -KILL $pids 2>/dev/null || true
fi

step "恢复 App" "Restoring the app"
rm -rf "$TARGET"
if [ "$(manifest had_app)" = "yes" ]; then
  ditto -x -k "$BACKUP/GoldenPassport.app.zip" "$APPS_DIR"
  info "已恢复 $TARGET" "Restored $TARGET"
else
  info "安装前没有 GoldenPassport，已删除新版" "GoldenPassport was not installed before, so the new version was removed"
fi

step "检查数据" "Checking data"
# What the restored app reads: 0.1.x its gp.secrets, a 0.2.x build without the Keychain
# accounts.json, one with it (Info.plist GPKeychainService) the login Keychain.
RESTORED=none
if [ -d "$TARGET" ]; then
  if /usr/libexec/PlistBuddy -c "Print :GPKeychainService" "$TARGET/Contents/Info.plist" >/dev/null 2>&1; then
    RESTORED=keychain
  elif /usr/libexec/PlistBuddy -c "Print :GPDataDirectoryName" "$TARGET/Contents/Info.plist" >/dev/null 2>&1; then
    RESTORED=0.2
  else
    RESTORED=0.1
  fi
fi
# accounts-v2.json: the accounts were moved into the login Keychain.
IN_KEYCHAIN=no
[ -f "$DATA_DIR/accounts-v2.json" ] && IN_KEYCHAIN=yes
if [ $RESTORE_DATA = 1 ]; then
  rm -rf "$DATA_DIR"
  [ -d "$BACKUP/data" ] && ditto "$BACKUP/data" "$DATA_DIR"
  info "数据目录已恢复到安装前" "The data folder is back to its state before the install"
  if [ $IN_KEYCHAIN = yes ] && [ ! -f "$DATA_DIR/accounts-v2.json" ]; then
    info "钥匙串里的账号条目保持不变。再次安装新版时会从恢复的数据重新迁移，原来的条目另存为 accounts.replaced-<时间>。" \
      "The accounts item in the keychain is left as it is. Installing the new version again migrates from the restored data and keeps the old item as accounts.replaced-<time>."
  fi
elif [ $RESTORED = keychain ] || { [ $RESTORED = 0.2 ] && [ $IN_KEYCHAIN = no ]; }; then
  info "数据保持不变：恢复的版本读取同样的数据，所有记录都在" \
    "Your data is unchanged: the restored version reads the same data, so all your accounts are there"
elif [ $RESTORED = 0.2 ]; then
  info "新版把账号存在登录钥匙串里，恢复的版本读不到，它看到的是迁移那一刻的 accounts.json。" \
    "The new version keeps your accounts in the login keychain. The restored version can't read them there; it sees accounts.json as it was when they moved."
  info "在新版里新增或修改的记录，恢复的版本看不到。需要的话，先在新版菜单里导出 .secrets，再导入恢复的版本。" \
    "Accounts added or changed in the new version are not visible to it. If you need them there, export a .secrets backup from the new version's menu and import it."
  info "再次升级后，新版继续使用钥匙串里的账号；在恢复的版本里做的改动不会自动带过去，cleanup.sh 删除 accounts.json 前会列出它们。" \
    "When you upgrade again, the new version keeps using the accounts in the keychain. Changes made in the restored version are not carried over; cleanup.sh lists them before it deletes accounts.json."
elif [ $RESTORED = none ]; then
  info "数据目录保持不变，再次安装时会继续使用" "The data folder is left as it is and is used again if you reinstall"
elif [ "$(checksum "$DATA_DIR/gp.secrets")" = "$(manifest gp_secrets_sha256)" ]; then
  info "gp.secrets 与备份一致，旧版能看到原来的全部记录" "gp.secrets matches the backup, so 0.1.x finds all its accounts"
else
  info "[警告] gp.secrets 与备份不一致，正在从备份恢复这个文件" \
    "[WARNING] gp.secrets differs from the backup; restoring it from the backup"
  cp -p "$BACKUP/data/gp.secrets" "$DATA_DIR/gp.secrets"
fi
if [ $RESTORE_DATA = 0 ] && [ $RESTORED = 0.1 ] && { [ -f "$DATA_DIR/accounts.json" ] || [ $IN_KEYCHAIN = yes ]; }; then
  if [ $IN_KEYCHAIN = yes ]; then
    info "新版的账号仍保存在登录钥匙串里，旧版不会读取；再次安装新版时会继续使用。" \
      "The new version's accounts stay in the login keychain. 0.1.x doesn't read them; the new version uses them again when you reinstall."
  else
    info "新版的 accounts.json 仍保留在数据目录里，旧版不会读取它；再次安装新版时会继续使用。" \
      "The new version's accounts.json stays in the data folder. 0.1.x doesn't read it; the new version uses it again when you reinstall."
  fi
  info "在新版里新增或修改的记录，旧版看不到。需要的话，先在新版菜单里导出 .secrets，再导入旧版。" \
    "Accounts added or changed in the new version are not visible to 0.1.x. If you need them there, export a .secrets backup from the new version's menu and import it into 0.1.x."
  info "反过来，回退后在旧版里做的改动，再次升级时 GoldenPassport 会提示你导入。" \
    "The other way round, when you upgrade again, GoldenPassport offers to import the changes you make in 0.1.x from now on."
fi

if [ "${GP_NO_LAUNCH:-0}" != "1" ] && [ -d "$TARGET" ]; then
  step "启动 GoldenPassport" "Starting GoldenPassport"
  open "$TARGET"
fi
printf '\n%s\n' "$(say "回退完成。备份仍保留在 $BACKUP" "Rollback complete. The backup stays in $BACKUP")"
printf '%s\n' "$(say "⚠️  备份中含有全部 MFA 密钥的未加密副本，请勿外传。不再需要时请删除：rm -rf \"$BACKUP_ROOT\"" \
  "⚠️  The backup holds an unencrypted copy of all your MFA secrets. Don't share it, and delete it when you no longer need it: rm -rf \"$BACKUP_ROOT\"")"
