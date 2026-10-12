#!/bin/bash
# =============================================================================
#  Compositor 简体中文汉化补丁 — 卸载脚本（v2）
#
#  移除汉化资源与 dylib，并从首次安装的备份还原原始（未注入）二进制，
#  使 app 完全回到安装前状态（含原始签名基础上的资源结构）。
# =============================================================================
set -euo pipefail

APP="${1:-/Applications/Compositor.app}"
BACKUP_DIR="$HOME/Library/Application Support/Compositor-zh-backup"

if [ -t 1 ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
    G=""; Y=""; R=""; N=""
fi
ok()   { printf "${G}✔${N} %s\n" "$*"; }
warn() { printf "${Y}⚠${N} %s\n" "$*"; }
err()  { printf "${R}✘${N} %s\n" "$*" >&2; }
step() { printf "\n==> %s\n" "$*"; }

step "检查环境"

if [ ! -d "$APP" ]; then
    err "未找到 $APP"
    exit 1
fi

if pgrep -f "$APP/Contents/MacOS/Compositor" >/dev/null 2>&1; then
    err "Compositor 正在运行，请先退出（⌘Q）。"
    exit 1
fi
ok "应用未在运行"

RES="$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/Compositor"

step "还原原始二进制"
if otool -l "$BIN" 2>/dev/null | grep -q "libCompositorZH.dylib"; then
    if [ -d "$BACKUP_DIR/Compositor.app" ]; then
        cp "$BACKUP_DIR/Compositor.app/Contents/MacOS/Compositor" "$BIN"
        ok "已从备份还原未注入的原始二进制"
    else
        err "检测到已注入但无备份，无法还原二进制。"
        err "请重新安装官方原版，或联系补丁提供者。"
        exit 1
    fi
else
    ok "二进制未注入，无需还原"
fi

step "移除汉化资源"
REMOVED=0
for d in zh-Hans.lproj zh_CN.lproj; do
    if [ -d "$RES/$d" ]; then
        rm -rf "$RES/$d"
        ok "已移除 $d"
        REMOVED=1
    else
        warn "未找到 $d（可能已卸载）"
    fi
done
if [ -f "$RES/libCompositorZH.dylib" ]; then
    rm -f "$RES/libCompositorZH.dylib"
    ok "已移除 libCompositorZH.dylib"
    REMOVED=1
fi

if [ "$REMOVED" = "1" ]; then
    step "重新签名"
    if codesign --force --sign - "$APP" 2>/dev/null; then
        ok "签名完成"
    else
        err "签名失败"
        exit 1
    fi
    if codesign -v "$APP" 2>/dev/null; then
        ok "签名校验通过"
    fi
fi

step "完成"
printf "%s\n" "已恢复英文界面（原始二进制已还原）。备份仍保留在："
printf "  $BACKUP_DIR/Compositor.app\n\n"
printf "如需彻底删除备份：\n  rm -rf \"$BACKUP_DIR\"\n"
