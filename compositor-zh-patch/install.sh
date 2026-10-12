#!/bin/bash
# =============================================================================
#  Compositor 简体中文汉化补丁 — 安装脚本（v2：资源 + 运行时 AppKit 汉化）
#
#  两层机制：
#   A. zh-Hans.lproj/Localizable.strings
#      覆盖全部 SwiftUI LocalizedStringKey 字面量（面板、对话框、提示、菜单标题等）。
#   B. libCompositorZH.dylib + 二进制注入（LC_LOAD_DYLIB）
#      滤镜名、混合模式等来自 enum rawValue（运行时 String），不走本地化查询；
#      这些标题最终经 NSMenuItem/NSButton 的 setTitle: 设置，dylib 在该入口
#      查 AppKitOverrides.plist 翻译。混合模式会被回读 title 解析枚举，故其
#      title 保持英文、改用 attributedTitle 显示中文，功能不受影响。
#
#  脚本步骤：备份原 .app → 装资源 → 拷 dylib → 注入加载命令 → 重签名。
#  升级会整体替换 .app，汉化随之失效，重跑本脚本即可，不影响升级。
# =============================================================================
set -euo pipefail

APP="${1:-/Applications/Compositor.app}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/Library/Application Support/Compositor-zh-backup"
STAMP="$BACKUP_DIR/installed-version.txt"

if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi

say()  { printf "%s\n" "$*"; }
ok()   { printf "${G}✔${N} %s\n" "$*"; }
warn() { printf "${Y}⚠${N} %s\n" "$*"; }
err()  { printf "${R}✘${N} %s\n" "$*" >&2; }
step() { printf "\n${B}==>${N} %s\n" "$*"; }

step "检查环境"

if [ ! -d "$APP" ]; then
    err "未找到 $APP，请先安装 Compositor。"
    exit 1
fi
ok "找到应用：$APP"

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
ok "应用版本：$VERSION"

if pgrep -f "$APP/Contents/MacOS/Compositor" >/dev/null 2>&1; then
    err "Compositor 正在运行，请先退出（⌘Q）后再安装。"
    exit 1
fi
ok "应用未在运行"

# 检查补丁文件
for f in zh-Hans.lproj/Localizable.strings zh-Hans.lproj/AppKitOverrides.plist \
         zh_CN.lproj/Localizable.strings zh_CN.lproj/AppKitOverrides.plist \
         libCompositorZH.dylib inject_dylib.py; do
    if [ ! -f "$PATCH_DIR/$f" ]; then
        err "补丁文件缺失：$PATCH_DIR/$f"
        exit 1
    fi
done
ok "补丁文件完整"

SYS_LANG=$(defaults read -g AppleLanguages 2>/dev/null | grep -o 'zh-Hans[a-zA-Z-]*' | head -1 || true)
if [ -z "$SYS_LANG" ]; then
    warn "系统首选语言不是简体中文。"
    warn "请到 系统设置 › 语言与地区，把「简体中文」拖到最顶部，然后重启 Compositor。"
else
    ok "系统语言：$SYS_LANG"
fi

# ---------- 备份（原始未注入的二进制）----------
step "备份原始应用"
mkdir -p "$BACKUP_DIR"
if [ ! -d "$BACKUP_DIR/Compositor.app" ]; then
    cp -R "$APP" "$BACKUP_DIR/Compositor.app"
    ok "已完整备份到：$BACKUP_DIR/Compositor.app"
elif [ ! -f "$STAMP" ]; then
    # 备份存在但没有版本记录：重新备份，确保二进制是未注入的原版
    rm -rf "$BACKUP_DIR/Compositor.app"
    cp -R "$APP" "$BACKUP_DIR/Compositor.app"
    ok "已刷新备份：$BACKUP_DIR/Compositor.app"
else
    ok "已存在备份（保留首次安装前的原始版本）"
fi

# 若之前注入过（重复安装/升级后重装），先从备份还原干净的二进制
BIN="$APP/Contents/MacOS/Compositor"
if otool -l "$BIN" 2>/dev/null | grep -q "libCompositorZH.dylib"; then
    if [ -d "$BACKUP_DIR/Compositor.app" ]; then
        cp "$BACKUP_DIR/Compositor.app/Contents/MacOS/Compositor" "$BIN"
        ok "已从备份还原原始二进制（重新注入）"
    else
        err "检测到已注入但无备份可还原，中止以防损坏。"
        exit 1
    fi
fi

# ---------- 安装资源 ----------
step "安装汉化资源"
RES="$APP/Contents/Resources"

for d in zh-Hans.lproj zh_CN.lproj; do
    rm -rf "$RES/$d"
    cp -R "$PATCH_DIR/$d" "$RES/$d"
    ok "已安装 $d ($(wc -l < "$RES/$d/Localizable.strings" | tr -d ' ') 行)"
done

# ---------- 安装 dylib 并注入 ----------
step "安装运行时汉化引擎（dylib 注入）"
cp "$PATCH_DIR/libCompositorZH.dylib" "$RES/libCompositorZH.dylib"
ok "已复制 dylib"

if /Users/zj/.workbuddy/binaries/python/envs/default/bin/python "$PATCH_DIR/inject_dylib.py" \
    "$BIN" "@executable_path/../Resources/libCompositorZH.dylib"; then
    ok "LC_LOAD_DYLIB 注入完成"
else
    err "注入失败，正在回滚…"
    cp "$BACKUP_DIR/Compositor.app/Contents/MacOS/Compositor" "$BIN" 2>/dev/null || true
    rm -rf "$RES/zh-Hans.lproj" "$RES/zh_CN.lproj" "$RES/libCompositorZH.dylib"
    codesign --force --sign - "$APP" 2>/dev/null || true
    exit 1
fi

# ---------- 重新签名 ----------
step "重新签名"
if codesign --force --sign - "$APP" 2>/dev/null; then
    ok "ad-hoc 签名完成"
else
    err "签名失败，正在回滚…"
    cp "$BACKUP_DIR/Compositor.app/Contents/MacOS/Compositor" "$BIN" 2>/dev/null || true
    rm -rf "$RES/zh-Hans.lproj" "$RES/zh_CN.lproj" "$RES/libCompositorZH.dylib"
    codesign --force --sign - "$APP" 2>/dev/null || true
    exit 1
fi

if codesign -v "$APP" 2>/dev/null; then
    ok "签名校验通过"
else
    err "签名校验失败"
    exit 1
fi

printf '%s\n' "$VERSION" > "$STAMP"

step "完成"
say "汉化已安装。现在启动 Compositor 即可看到中文界面。"
say ""
say "  ${B}首次启动${N}：若系统提示「已损坏」或无法打开，到 系统设置 › 隐私与安全性"
say "  点「仍要打开」；或执行 xattr -dr com.apple.quarantine \"$APP\""
say ""
say "  ${B}升级应用后${N}：更新会替换整个 .app，汉化失效，重新运行本脚本即可。"
say ""
say "  ${B}恢复英文${N}：运行 ./uninstall.sh（自动从备份还原原始二进制）"
