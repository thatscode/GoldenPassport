#!/bin/bash
# Deletes the unencrypted secret copies an upgrade from 0.1.x leaves behind, once
# the user is happy with 0.2.x and no longer needs to roll back:
#   - installer backups in ~/GoldenPassport-backups/
#   - the legacy gp.secrets / config.plist in the data directory
#     (and legacy-baseline.json, which only describes gp.secrets)
#   - accounts.json, once the installed build keeps the accounts in the login Keychain
#
#   bash cleanup.sh [--yes]
#
# Refuses to run unless 0.2.x is installed and its accounts read back cleanly.
# Warns about accounts changed in 0.1.x after the migration that were never
# imported, and about accounts only accounts.json still has: their only copies are
# about to be deleted. Afterwards rollback.sh can no longer restore 0.1.x or a beta.
#
# Messages are in Simplified Chinese or English, like the app (see ui_language).
# Environment overrides (for testing): GP_APPLICATIONS_DIR, GP_DATA_DIR, GP_BACKUP_ROOT,
# GP_LANG=zh-Hans|en.
set -euo pipefail

# 0.2.1 moved the bundle id; 0.1.x and 0.2.0 used the old one.
BUNDLE_ID="com.thatscode.GoldenPassport"
LEGACY_BUNDLE_ID="site.stanzhai.GoldenPassport"
APPS_DIR="${GP_APPLICATIONS_DIR:-/Applications}"
DATA_DIR="${GP_DATA_DIR:-$HOME/Library/Application Support/GoldenPassport}"
BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"
TARGET="$APPS_DIR/GoldenPassport.app"

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

usage() {
  say "用法：bash cleanup.sh [--yes]

确认 0.2.x 使用正常、不再需要回退后，删除从 0.1.x 升级时留下的未加密密钥副本：
  - $BACKUP_ROOT 里的安装备份
  - 数据目录里旧版的 gp.secrets / config.plist
  - 账号已经存进钥匙串时，数据目录里内测版的 accounts.json
只有在已安装 0.2.x、并且账号读取正常时才会执行。删除前要输入 yes 确认，
--yes 跳过确认。清理之后，rollback.sh 就不能再回退到 0.1.x 或内测版了。
" "Usage: bash cleanup.sh [--yes]

Once 0.2.x works for you and you no longer need to roll back, deletes the
unencrypted copies of your secrets that the upgrade from 0.1.x left behind:
  - the installer backups in $BACKUP_ROOT
  - the legacy gp.secrets / config.plist in the data folder
  - the beta's accounts.json, once your accounts are in the keychain
Runs only if 0.2.x is installed and your accounts read back cleanly. Asks you to
type yes before deleting; --yes skips that. Afterwards rollback.sh can no longer
restore 0.1.x or a beta.
"
}

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s\n' "$(say "未知参数：$arg" "Unknown option: $arg")" >&2; exit 1 ;;
  esac
done

step() { printf '\n==> %s\n' "$(say "$@")"; }
info() { printf '    %s\n' "$(say "$@")"; }
die() { printf '\n%s %s\n' "$(say '[停止]' '[STOPPED]')" "$(say "$@")" >&2; exit 1; }

# --- 1. Safety checks -------------------------------------------------------
step "检查新版数据" "Checking the new version's data"
[ -d "$TARGET" ] || die "没有找到 $TARGET" "$TARGET not found"
/usr/libexec/PlistBuddy -c "Print :GPDataDirectoryName" "$TARGET/Contents/Info.plist" >/dev/null 2>&1 \
  || die "当前安装的还是 0.1.x 旧版，它的数据就在 gp.secrets 里，不能清理" \
    "The installed app is still 0.1.x, and gp.secrets is its data, so nothing can be cleaned up"

set +e
REPORT="$("$TARGET/Contents/MacOS/GoldenPassport" --migrate-data --data-dir "$DATA_DIR" 2>&1)"
STATUS=$?
set -e
report_value() { printf '%s\n' "$REPORT" | sed -n "s/^$1=//p" | head -n 1; }
[ $STATUS -eq 0 ] || { printf '%s\n' "$REPORT" | sed 's/^/    /'; die "新版数据读取或核对失败，为安全起见不做清理" \
  "Reading or checking the new version's data failed. To be safe, nothing was deleted"; }
CURRENT="$(report_value account_count)"
LEGACY="$(report_value legacy_count)"
STORAGE="$(report_value storage)"
if [ "$STORAGE" = keychain ]; then
  info "登录钥匙串里的账号：$CURRENT 条记录，读取正常" "Accounts in the login keychain: $(plural "$CURRENT" account accounts), read back fine"
else
  info "新版 accounts.json：$CURRENT 条记录，读取正常" "accounts.json: $(plural "$CURRENT" account accounts), reads back fine"
fi

# --- 2. What will be deleted ------------------------------------------------
step "将要删除的内容（都含有未加密的 MFA 密钥）" "To be deleted (all of it holds unencrypted MFA secrets)"
TARGETS=()
if [ -d "$BACKUP_ROOT" ]; then
  COUNT="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  info "• 安装备份：${BACKUP_ROOT}（${COUNT} 份）" "• Installer backups: $BACKUP_ROOT ($COUNT)"
  TARGETS+=("$BACKUP_ROOT")
fi
for name in gp.secrets config.plist; do
  if [ -f "$DATA_DIR/$name" ]; then
    info "• 旧版数据文件：$DATA_DIR/$name" "• 0.1.x data file: $DATA_DIR/$name"
    TARGETS+=("$DATA_DIR/$name")
  fi
done
# Once the accounts are in the Keychain, accounts.json is only a plaintext copy for rolling
# back to a beta build.
if [ "$STORAGE" = keychain ] && [ -f "$DATA_DIR/accounts.json" ]; then
  info "• 内测版的数据文件：$DATA_DIR/accounts.json" "• Beta data file: $DATA_DIR/accounts.json"
  TARGETS+=("$DATA_DIR/accounts.json")
fi
[ ${#TARGETS[@]} -gt 0 ] || { info "没有需要清理的内容。" "Nothing to clean up."; exit 0; }
# The record of what gp.secrets held (names and fingerprints, no secrets) goes with it.
if [ -f "$DATA_DIR/gp.secrets" ] && [ -f "$DATA_DIR/legacy-baseline.json" ]; then
  info "  同时删除 legacy-baseline.json：它只记录 gp.secrets 里的账号名称，不含密钥" \
    "  Also deletes legacy-baseline.json, which only records the account names in gp.secrets, no secrets"
  TARGETS+=("$DATA_DIR/legacy-baseline.json")
fi

if [ "$LEGACY" != "none" ] && [ "$CURRENT" -lt "$LEGACY" ]; then
  info ""
  info "⚠️  旧版 gp.secrets 有 $LEGACY 条，新版只有 $CURRENT 条。" \
    "⚠️  gp.secrets holds $(plural "$LEGACY" account accounts), the new version only $CURRENT."
  info "    少的那些通常是你在新版里删掉的；清理后将无法再从旧版数据中找回。" \
    "    The missing ones are usually accounts you deleted in the new version; after the cleanup they can't be recovered from the 0.1.x data."
fi

# Accounts added or changed in 0.1.x after the migration (e.g. after rollback.sh) and never
# imported: gp.secrets and the backups hold their only copies. Warn, but let the user decide.
IMPORTS="$(report_value legacy_imports)"
if [ "${IMPORTS:-0}" -gt 0 ] && [ -f "$DATA_DIR/gp.secrets" ]; then
  info ""
  info "⚠️  回退期间，0.1.x 新增或改过 $IMPORTS 个账号，还没有导入新版本：" \
    "⚠️  Not imported into the new version yet: $(plural "$IMPORTS" account accounts) added or changed in 0.1.x after the upgrade:"
  printf '%s\n' "$REPORT" | sed -n 's/^legacy_change=//p' | while IFS= read -r change; do
    case "${change%%:*}" in
      added|changed) info "      • ${change#*:}" ;;
    esac
  done
  info "    它们的密钥只在 gp.secrets 和安装备份里，清理后将永久丢失。" \
    "    Their secrets exist only in gp.secrets and the installer backups, so the cleanup deletes them for good."
  info "    建议先打开 GoldenPassport，按提示导入，再运行清理。" \
    "    Open GoldenPassport and import them when it asks, then run the cleanup again."
fi
# Accounts accounts.json has and the Keychain doesn't (by URL): deleted in the new version,
# or added or changed in a beta build after a rollback (design 5.4, decision 4).
FILE_ONLY="$(printf '%s\n' "$REPORT" | sed -n 's/^file_only=//p')"
if [ "$STORAGE" = keychain ] && [ -n "$FILE_ONLY" ] && [ -f "$DATA_DIR/accounts.json" ]; then
  COUNT="$(printf '%s\n' "$FILE_ONLY" | wc -l | tr -d ' ')"
  info ""
  info "⚠️  accounts.json 里有 $COUNT 个账号不在钥匙串里：" \
    "⚠️  accounts.json has $(plural "$COUNT" account accounts) that the keychain doesn't:"
  printf '%s\n' "$FILE_ONLY" | while IFS= read -r name; do info "      • $name"; done
  info "    可能是你在新版里删掉的，也可能是回退到内测版期间新增或改过的。清理后将无法找回。" \
    "    You may have deleted them in the new version, or added or changed them in a beta after rolling back. After the cleanup they can't be recovered."
  info "    需要保留的话，先用 rollback.sh 回到内测版导出 .secrets，再装回新版并导入，然后再运行清理。" \
    "    To keep them, go back to the beta with rollback.sh and export a .secrets file, then reinstall the new version, import it, and run the cleanup again."
fi
info ""
info "清理后：rollback.sh 无法再回退到旧版；新版的使用不受任何影响。" \
  "Afterwards rollback.sh can no longer restore 0.1.x. The new version works exactly as before."
info "你自己导出的 .secrets / .txt 文件不在清理范围内，请自行删除。" \
  "Files you exported yourself (.secrets / .txt) are not touched; delete them yourself."

# --- 3. Confirm & delete ----------------------------------------------------
if [ $ASSUME_YES -ne 1 ]; then
  printf '\n%s' "$(say '确认删除以上内容？请输入 yes 并回车：' 'Delete everything listed above? Type yes and press Return: ')"
  read -r answer || answer=""
  [ "$answer" = "yes" ] || die "已取消，没有删除任何文件" "Cancelled. Nothing was deleted"
fi

step "删除" "Deleting"
for path in "${TARGETS[@]}"; do
  rm -rf "$path"
  info "已删除 $path" "Deleted $path"
done
if [ "$STORAGE" = keychain ]; then
  printf '\n%s\n' "$(say "清理完成。你的账号保存在登录钥匙串里，新版照常使用。" \
    "Cleanup complete. Your accounts are in the login keychain, and the new version works as before.")"
else
  printf '\n%s\n' "$(say "清理完成。你的账号保存在 $DATA_DIR/accounts.json，新版照常使用。" \
    "Cleanup complete. Your accounts are in $DATA_DIR/accounts.json, and the new version works as before.")"
fi
