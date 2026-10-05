#!/bin/bash
# Restores the GoldenPassport app that install.sh replaced.
#
#   bash rollback.sh [--restore-data] [backup-dir]
#
# By default only the app is restored: 0.2.x never writes gp.secrets, so the old
# app finds its data unchanged. --restore-data also resets the whole data
# directory to its pre-install state, discarding changes made in 0.2.x.
#
# Environment overrides (for testing): GP_BACKUP_ROOT, GP_NO_LAUNCH=1.
set -euo pipefail

BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"
RESTORE_DATA=0
BACKUP=""
for arg in "$@"; do
  case "$arg" in
    --restore-data) RESTORE_DATA=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) BACKUP="$arg" ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }
checksum() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "none"; }

if [ -z "$BACKUP" ]; then
  BACKUP="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n 1 || true)"
  [ -n "$BACKUP" ] || die "在 $BACKUP_ROOT 下没有找到备份"
fi
BACKUP="${BACKUP%/}"
MANIFEST="$BACKUP/manifest.txt"
[ -f "$MANIFEST" ] || die "$BACKUP 不是 install.sh 生成的备份（缺少 manifest.txt）"
manifest() { sed -n "s/^$1=//p" "$MANIFEST" | head -n 1; }

APPS_DIR="$(manifest apps_dir)"
DATA_DIR="$(manifest data_dir)"
TARGET="$APPS_DIR/GoldenPassport.app"

step "回退计划"
info "备份：${BACKUP}（$(manifest date)）"
info "当前：$(manifest installed_version) → 回退到：$(manifest previous_version)"
info "数据：$([ $RESTORE_DATA = 1 ] && echo "整个数据目录恢复到安装前（0.2.x 中的改动会丢失）" || echo "保持不变")"

step "退出 GoldenPassport"
pids="$(pgrep -f "^$TARGET/Contents/MacOS/" || true)"
if [ -n "$pids" ]; then
  kill -TERM $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "^$TARGET/Contents/MacOS/" >/dev/null || break
    sleep 0.5
  done
  kill -KILL $pids 2>/dev/null || true
fi

step "恢复 App"
rm -rf "$TARGET"
if [ "$(manifest had_app)" = "yes" ]; then
  ditto -x -k "$BACKUP/GoldenPassport.app.zip" "$APPS_DIR"
  info "已恢复 $TARGET"
else
  info "安装前没有 GoldenPassport，已删除新版"
fi

step "检查数据"
if [ $RESTORE_DATA = 1 ]; then
  rm -rf "$DATA_DIR"
  [ -d "$BACKUP/data" ] && ditto "$BACKUP/data" "$DATA_DIR"
  info "数据目录已恢复到安装前"
elif [ "$(checksum "$DATA_DIR/gp.secrets")" = "$(manifest gp_secrets_sha256)" ]; then
  info "gp.secrets 与备份一致，旧版能看到原来的全部记录"
else
  info "[警告] gp.secrets 与备份不一致，正在从备份恢复这个文件"
  cp -p "$BACKUP/data/gp.secrets" "$DATA_DIR/gp.secrets"
fi
if [ $RESTORE_DATA = 0 ] && [ -f "$DATA_DIR/accounts.json" ]; then
  info "新版的 accounts.json 仍保留在数据目录里，旧版不会读取它；再次安装新版时会继续使用。"
  info "在新版里新增或修改的记录，旧版看不到。需要的话，先在新版菜单里导出 .secrets，再导入旧版。"
fi

if [ "${GP_NO_LAUNCH:-0}" != "1" ] && [ -d "$TARGET" ]; then
  step "启动 GoldenPassport"
  open "$TARGET"
fi
printf '\n回退完成。备份仍保留在 %s\n' "$BACKUP"
