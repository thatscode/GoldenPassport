#!/bin/bash
# Deletes the unencrypted secret copies an upgrade from 0.1.x leaves behind, once
# the user is happy with 0.2.x and no longer needs to roll back:
#   - installer backups in ~/GoldenPassport-backups/
#   - the legacy gp.secrets / config.plist in the data directory
#
#   bash cleanup.sh [--yes]
#
# Refuses to run unless 0.2.x is installed and accounts.json reads back cleanly.
# Afterwards rollback.sh can no longer restore 0.1.x.
#
# Environment overrides (for testing): GP_APPLICATIONS_DIR, GP_DATA_DIR, GP_BACKUP_ROOT.
set -euo pipefail

APPS_DIR="${GP_APPLICATIONS_DIR:-/Applications}"
DATA_DIR="${GP_DATA_DIR:-$HOME/Library/Application Support/GoldenPassport}"
BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"
TARGET="$APPS_DIR/GoldenPassport.app"
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf '未知参数：%s\n' "$arg" >&2; exit 1 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\n[停止] %s\n' "$*" >&2; exit 1; }

# --- 1. Safety checks -------------------------------------------------------
step "检查新版数据"
[ -d "$TARGET" ] || die "没有找到 $TARGET"
/usr/libexec/PlistBuddy -c "Print :GPDataDirectoryName" "$TARGET/Contents/Info.plist" >/dev/null 2>&1 \
  || die "当前安装的还是 0.1.x 旧版，它的数据就在 gp.secrets 里，不能清理"

set +e
REPORT="$("$TARGET/Contents/MacOS/GoldenPassport" --migrate-data --data-dir "$DATA_DIR" 2>&1)"
STATUS=$?
set -e
report_value() { printf '%s\n' "$REPORT" | sed -n "s/^$1=//p" | head -n 1; }
[ $STATUS -eq 0 ] || { printf '%s\n' "$REPORT" | sed 's/^/    /'; die "新版数据读取或核对失败，为安全起见不做清理"; }
CURRENT="$(report_value account_count)"
LEGACY="$(report_value legacy_count)"
info "新版 accounts.json：$CURRENT 条记录，读取正常"

# --- 2. What will be deleted ------------------------------------------------
step "将要删除的内容（都含有未加密的 MFA 密钥）"
TARGETS=()
if [ -d "$BACKUP_ROOT" ]; then
  COUNT="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  info "• 安装备份：${BACKUP_ROOT}（${COUNT} 份）"
  TARGETS+=("$BACKUP_ROOT")
fi
for name in gp.secrets config.plist; do
  if [ -f "$DATA_DIR/$name" ]; then
    info "• 旧版数据文件：$DATA_DIR/$name"
    TARGETS+=("$DATA_DIR/$name")
  fi
done
[ ${#TARGETS[@]} -gt 0 ] || { info "没有需要清理的内容。"; exit 0; }

if [ "$LEGACY" != "none" ] && [ "$CURRENT" -lt "$LEGACY" ]; then
  info ""
  info "⚠️  旧版 gp.secrets 有 $LEGACY 条，新版只有 $CURRENT 条。"
  info "    少的那些通常是你在新版里删掉的；清理后将无法再从旧版数据中找回。"
fi
info ""
info "清理后：rollback.sh 无法再回退到旧版；新版的使用不受任何影响。"
info "你自己导出的 .secrets / .txt 文件不在清理范围内，请自行删除。"

# --- 3. Confirm & delete ----------------------------------------------------
if [ $ASSUME_YES -ne 1 ]; then
  printf '\n确认删除以上内容？请输入 yes 并回车：'
  read -r answer
  [ "$answer" = "yes" ] || die "已取消，没有删除任何文件"
fi

step "删除"
for path in "${TARGETS[@]}"; do
  rm -rf "$path"
  info "已删除 $path"
done
printf '\n清理完成。你的账号保存在 %s/accounts.json，新版照常使用。\n' "$DATA_DIR"
