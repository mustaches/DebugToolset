#!/usr/bin/env bash
# DebugToolSet Linux .deb 打包脚本（在 Ubuntu/WSL 中运行）。
#
# 前置条件：
#   1. 已执行 flutter build linux --release（产物在 build/linux/x64/release/bundle/）
#   2. 在工程根目录或其子目录运行均可，脚本自行定位工程根
#
# 产出：Linux_setup/Output/debug-tool-set_<版本>_amd64.deb
#
# 说明：
#   - 程序装入 /opt/debug_tool_set/，启动器装入 /usr/bin/debug-tool-set
#   - 运行时数据目录（bussetup/ DeviceProtocol/ docs/ waveform/ IspFlow/ UI_Project/）
#     装入 /opt/debug_tool_set/data/，首次启动由启动器复制到用户目录（见 debug-tool-set）
#   - Depends 由 ldd + dpkg -S 自动从二进制依赖推导，另加 ffmpeg（ISP Studio 视频导出）
#     与 fonts-noto-cjk（中文界面字体，缺失会显示方框）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
[ -x "$BUNDLE/debug_tool_set" ] || { echo "未找到 release 产物，请先 flutter build linux --release"; exit 1; }

PKG=debug-tool-set
VER="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$ROOT/pubspec.yaml")"
ARCH=amd64
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/${PKG}_${VER}_${ARCH}"

# ---- 程序与数据 ----
mkdir -p "$STAGE/opt/debug_tool_set/data"
cp -a "$BUNDLE/." "$STAGE/opt/debug_tool_set/"
for d in bussetup DeviceProtocol docs waveform IspFlow UI_Project; do
  [ -d "$ROOT/$d" ] && cp -a "$ROOT/$d" "$STAGE/opt/debug_tool_set/data/"
done

# ---- 启动器 / 桌面入口 / 图标 ----
install -Dm755 "$ROOT/Linux_setup/debug-tool-set" "$STAGE/usr/bin/debug-tool-set"
install -Dm644 "$ROOT/Linux_setup/debug-tool-set.desktop" \
  "$STAGE/usr/share/applications/debug-tool-set.desktop"
install -Dm644 "$ROOT/LXI_Logo/LXI_Logo_2.png" \
  "$STAGE/usr/share/icons/hicolor/256x256/apps/debug-tool-set.png"

# ---- 依赖推导（二进制 -> 库 -> 所属 deb 包）----
# 注意：Ubuntu 24.04 为 merged-/usr 布局，ldd 报的 /lib/... 在 dpkg 数据库里
# 记为 /usr/lib/...，需先做路径归一化；应用自带 lib/*.so 不属于任何 deb 包，过滤掉。
DEPS="$(
  { ldd "$STAGE/opt/debug_tool_set/debug_tool_set"; \
    ldd "$STAGE/opt/debug_tool_set"/lib/*.so; } 2>/dev/null \
  | awk '/=>/{print $3}' | sed 's|^/lib/|/usr/lib/|' | sort -u \
  | grep '^/usr/lib/' \
  | xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | cut -d, -f1 | sort -u \
  | paste -sd, || true
)"
DEPS="${DEPS:+$DEPS, }ffmpeg, fonts-noto-cjk"

SIZE="$(du -sk "$STAGE" | cut -f1)"

# ---- control ----
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER
Section: devel
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE
Depends: $DEPS
Maintainer: DebugToolSet developers <noreply@example.com>
Description: 嵌入式/硬件调试多功能工具集（示波器、终端、Hex 编辑、文本对比、字库提取、UI 设计器、ISP Studio）
EOF

# ---- 构建 ----
OUT="$ROOT/Linux_setup/Output"
mkdir -p "$OUT"
# dpkg-deb 要求属主合理；/mnt/* (drvfs) 上权限不可靠，因此全程在 $WORK 内操作
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/${PKG}_${VER}_${ARCH}.deb"
echo "OK: $OUT/${PKG}_${VER}_${ARCH}.deb"
