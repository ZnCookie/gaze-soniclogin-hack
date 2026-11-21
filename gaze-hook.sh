#!/usr/bin/env bash
# 单文件：安装 pacman hook（install），并被 hook 回调以重套 wrapper（无参）。
#   sudo bash gaze-hook.sh install   安装 hook + 立即应用一次
#   sudo bash gaze-hook.sh            被 hook 调用 / 手动重套（幂等）
set -euo pipefail

HELPER=/usr/lib/soniclogin-helper
REAL=/usr/lib/soniclogin-helper.real
SHIM=/usr/local/lib/gaze_service_shim.so
SELF=/usr/local/bin/gaze-hook.sh
HOOK=/etc/pacman.d/hooks/gaze-hook.hook
log() { printf '[gaze-hook] %s\n' "$*" >&2; }

apply() {
    [ -f "$HELPER" ] || { log "helper 不存在，跳过"; return; }
    [ -f "$SHIM" ]   || { log "shim 不存在，跳过"; return; }
    [ "$(head -c 2 "$HELPER")" = '#!' ] && { log "已是 wrapper，跳过"; return; }
    log "检测到升级后的真二进制，重套 wrapper"
    cp -a "$HELPER" "$REAL"
    cat > "$HELPER" <<'EOF'
#!/bin/sh
LD_PRELOAD=/usr/local/lib/gaze_service_shim.so
export LD_PRELOAD
exec /usr/lib/soniclogin-helper.real "$@"
EOF
    chmod 755 "$HELPER"
    log "完成（原件备份于 $REAL）"
}

case "${1:-apply}" in
  install)
    [ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }
    install -m 755 "$0" "$SELF"
    install -d "$(dirname "$HOOK")"
    cat > "$HOOK" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/soniclogin-helper

[Action]
Description = Reapply Gaze wrapper to soniclogin-helper...
When = PostTransaction
Exec = $SELF
EOF
    log "hook 已安装：$HOOK"
    apply
    ;;
  apply) apply ;;
  *) echo "用法: sudo bash gaze-hook.sh [install]"; exit 1 ;;
esac
