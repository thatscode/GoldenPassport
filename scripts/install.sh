#!/bin/bash
# Installs (or upgrades to) GoldenPassport 0.2.x over an existing installation.
#
#   bash install.sh [GoldenPassport.app | GoldenPassport-*.zip]
#
# Steps: check the package -> back up the installed app and data directory ->
# quit the running app -> replace /Applications/GoldenPassport.app -> migrate and
# verify data (names only, never secrets) -> launch. If migration does not verify,
# the previous app and data are restored automatically.
#
# WARNING: the backup in ~/GoldenPassport-backups/ is an UNENCRYPTED copy of every
# MFA secret. It is made owner-only (chmod go-rwx); users must delete it once they
# no longer need to roll back.
#
# Environment overrides (for testing): GP_APPLICATIONS_DIR, GP_DATA_DIR,
# GP_BACKUP_ROOT, GP_NO_LAUNCH=1.
set -euo pipefail

BUNDLE_ID="site.stanzhai.GoldenPassport"
APPS_DIR="${GP_APPLICATIONS_DIR:-/Applications}"
DATA_DIR="${GP_DATA_DIR:-$HOME/Library/Application Support/GoldenPassport}"
BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"
TARGET="$APPS_DIR/GoldenPassport.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

describe_app() {
  local app="$1"
  [ -d "$app" ] || { echo "未安装"; return; }
  if [ -n "$(plist_value "$app" GPDataDirectoryName)" ]; then
    echo "$(plist_value "$app" CFBundleShortVersionString) (build $(plist_value "$app" CFBundleVersion))"
  else
    echo "0.1.x 旧版"
  fi
}

# Quits only processes running from $1, so a test install never touches the real app.
quit_app() {
  local app="$1" pids i
  pids="$(pgrep -f "^$app/Contents/MacOS/" || true)"
  [ -n "$pids" ] || return 0
  info "正在退出运行中的 GoldenPassport (pid $(echo $pids))"
  kill -TERM $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "^$app/Contents/MacOS/" >/dev/null || return 0
    sleep 0.5
  done
  kill -KILL $pids 2>/dev/null || true
  sleep 0.5
}

checksum() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "none"; }

# --- 1. Package -------------------------------------------------------------
step "检查安装包"
SOURCE="${1:-$SCRIPT_DIR/GoldenPassport.app}"
WORK="$(mktemp -d -t gp-install)"
trap 'rm -rf "$WORK"' EXIT
case "$SOURCE" in
  *.zip)
    ditto -x -k "$SOURCE" "$WORK/unzipped"
    SOURCE="$(find "$WORK/unzipped" -maxdepth 2 -name GoldenPassport.app -type d | head -n 1)"
    [ -n "$SOURCE" ] || die "压缩包里没有 GoldenPassport.app" ;;
esac
[ -d "$SOURCE" ] || die "找不到安装包：$SOURCE"
SOURCE="$(cd "$SOURCE" && pwd)"
[ "$SOURCE" != "$TARGET" ] || die "安装包就是已安装的 App，请指定新下载的 GoldenPassport.app"

[ "$(plist_value "$SOURCE" CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "不是 GoldenPassport 正式版安装包（Bundle ID 不符）"
[ -n "$(plist_value "$SOURCE" GPDataDirectoryName)" ] || die "这是 0.1.x 旧版安装包，回退请用 rollback.sh"
codesign --verify --strict "$SOURCE" 2>/dev/null || die "安装包签名校验失败，可能已损坏，请重新下载"

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 13 ] || die "需要 macOS 13 或更高版本，当前是 $(sw_vers -productVersion)"
ARCH="$(uname -m)"
lipo -archs "$SOURCE/Contents/MacOS/GoldenPassport" | tr ' ' '\n' | grep -qx "$ARCH" \
  || die "安装包不支持这台 Mac 的架构 ($ARCH)，请使用通用版 (Universal) 安装包"

NEW_VERSION="$(describe_app "$SOURCE")"
OLD_VERSION="$(describe_app "$TARGET")"
info "新版本：$NEW_VERSION"
info "当前已安装：$OLD_VERSION"
info "数据目录：$DATA_DIR"

# --- 2. Backup --------------------------------------------------------------
step "备份当前的 App 和数据"
BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP_ROOT" "$BACKUP"
if [ -d "$TARGET" ]; then
  # A zip, not a second .app: two bundles with the same id confuse Launch Services.
  ditto -c -k --keepParent "$TARGET" "$BACKUP/GoldenPassport.app.zip"
  info "App → $BACKUP/GoldenPassport.app.zip"
fi
if [ -d "$DATA_DIR" ]; then
  ditto "$DATA_DIR" "$BACKUP/data"
  info "数据 → $BACKUP/data"
fi
chmod -R go-rwx "$BACKUP"
info "⚠️  备份里有你全部 MFA 密钥的未加密副本（权限：仅本人可读）"
{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "previous_version=$OLD_VERSION"
  echo "installed_version=$NEW_VERSION"
  echo "apps_dir=$APPS_DIR"
  echo "data_dir=$DATA_DIR"
  echo "had_app=$([ -d "$TARGET" ] && echo yes || echo no)"
  echo "had_data=$([ -d "$DATA_DIR" ] && echo yes || echo no)"
  echo "gp_secrets_sha256=$(checksum "$DATA_DIR/gp.secrets")"
} > "$BACKUP/manifest.txt"

restore_previous() {
  printf '\n==> 正在恢复安装前的状态\n'
  quit_app "$TARGET"
  rm -rf "$TARGET"
  if [ -f "$BACKUP/GoldenPassport.app.zip" ]; then
    ditto -x -k "$BACKUP/GoldenPassport.app.zip" "$APPS_DIR"
  fi
  rm -rf "$DATA_DIR"
  if [ -d "$BACKUP/data" ]; then
    ditto "$BACKUP/data" "$DATA_DIR"
  fi
  info "已恢复。备份保留在 $BACKUP"
}

# --- 3. Replace -------------------------------------------------------------
step "安装新版本"
quit_app "$TARGET"
STAGED="$APPS_DIR/.GoldenPassport.app.installing"
rm -rf "$STAGED"
ditto "$SOURCE" "$STAGED" || die "无法写入 ${APPS_DIR}，请确认当前账号有管理员权限"
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true
rm -rf "$TARGET"
mv "$STAGED" "$TARGET"
info "已安装到 $TARGET"

# --- 4. Migrate & verify ----------------------------------------------------
step "迁移并核对数据"
set +e
REPORT="$("$TARGET/Contents/MacOS/GoldenPassport" --migrate-data --data-dir "$DATA_DIR" 2>&1)"
STATUS=$?
set -e
report_value() { printf '%s\n' "$REPORT" | sed -n "s/^$1=//p" | head -n 1; }
if [ $STATUS -ne 0 ]; then
  printf '%s\n' "$REPORT" | sed 's/^/    /'
  restore_previous
  die "数据核对没有通过，已自动恢复到安装前的状态。请把上面的输出发给维护者。"
fi
case "$(report_value status)" in
  migrated) info "已从旧版迁移 $(report_value account_count) 条记录，与 gp.secrets 的 $(report_value legacy_count) 条逐条一致" ;;
  already-migrated) info "沿用已有数据：$(report_value account_count) 条记录" ;;
  no-data) info "没有发现旧数据，这是一次全新安装" ;;
esac
[ "$(checksum "$DATA_DIR/gp.secrets")" = "$(sed -n 's/^gp_secrets_sha256=//p' "$BACKUP/manifest.txt")" ] \
  || { restore_previous; die "gp.secrets 在安装过程中发生了变化，已自动恢复"; }
[ -f "$DATA_DIR/gp.secrets" ] && info "旧版数据文件 gp.secrets 未被改动，可随时回退"

# --- 5. Launch --------------------------------------------------------------
if [ "${GP_NO_LAUNCH:-0}" != "1" ]; then
  step "启动 GoldenPassport"
  open "$TARGET"
fi

cat <<EOF

安装完成：$OLD_VERSION → $NEW_VERSION

注意事项
  • 全局快捷键默认是 ⌃⌥⌘0–9（旧版是 ⇧⌘0–9），可在菜单「全局快捷键」里切换。
  • 自动填入验证码需要重新授权「辅助功能」：系统设置 → 隐私与安全性 → 辅助功能。
    如果列表里已有 GoldenPassport 但不生效，先用「−」删掉，再在菜单里重新选一次快捷键。
  • 回退到安装前的版本：bash "$SCRIPT_DIR/rollback.sh"

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ⚠️  重要：备份中含有全部 MFA 密钥的未加密副本
      $BACKUP
  • 拿到这个目录的人可以生成你所有账号的验证码。
  • 不要复制、上传、发给别人，也不要放进 iCloud / 网盘等同步目录。
  • 确认新版使用正常、不再需要回退后，请删除：
      rm -rf "$BACKUP_ROOT"
  • 数据目录里旧版的 gp.secrets 也会一直保留（供回退使用），
    其中包括你之后在新版里删除的记录。
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
