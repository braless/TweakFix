#!/bin/bash
# 构建产物导出：
#   只把主包（iphoneos-arm，arm64+arm64e）里的 dylib 以 Tweakfix.dylib 的名字
#   拷贝到 iCloud 云盘的「应用插件」目录，其他文件（带版本号的 dylib、arm64 单架构版）都不再拷贝。
#   文件名保持 Tweakfix.dylib，因为它需要和 Tweakfix.plist 同名才能被 Substrate 加载。
#
# 用法：
#   tools/export_artifacts.sh            # 版本号取 control 里的 Version
#   tools/export_artifacts.sh 0.0.27     # 指定版本号
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_DIR="$PROJECT_DIR/packages"
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
PLUGIN_DIR="$ICLOUD_DIR/应用插件"
DYLIB_NAME="Tweakfix.dylib"
PACKAGE_ID="com.oaife.tweakfix"

if [ ! -d "$PACKAGES_DIR" ]; then
    echo "packages 目录不存在：$PACKAGES_DIR" >&2
    exit 1
fi

VERSION="${1:-$(awk '/^Version:/ {print $2}' "$PROJECT_DIR/control")}"
if [ -z "$VERSION" ]; then
    echo "无法确定版本号（control 里没有 Version）" >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

shopt -s nullglob
debs=("$PACKAGES_DIR"/"$PACKAGE_ID"_"$VERSION"-*.deb)
if [ ${#debs[@]} -eq 0 ]; then
    echo "没有找到 $VERSION 的 deb：$PACKAGES_DIR/${PACKAGE_ID}_${VERSION}-*.deb" >&2
    exit 1
fi

primary_dylib=""
primary_source=""

for deb in "${debs[@]}"; do
    extract_dir="$tmp_dir/$(basename "$deb" .deb)"
    dpkg-deb -x "$deb" "$extract_dir"
    # rootful 在 Library/...，rootless(Dopamine) 在 var/jb/Library/...，直接按名字找
    src="$(find "$extract_dir" -name "$DYLIB_NAME" -print -quit)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "跳过（deb 内没有 dylib）：$deb" >&2
        continue
    fi
    # 始终覆盖：遍历所有匹配的 deb，取最后一个（即版本号/构建号最高、最新打的包）
    primary_dylib="$src"
    primary_source="$(basename "$deb")"
done

if [ -z "$primary_dylib" ]; then
    echo "没有可导出的 dylib" >&2
    exit 1
fi

if [ ! -d "$ICLOUD_DIR" ]; then
    echo "未找到 iCloud 云盘目录：$ICLOUD_DIR" >&2
    exit 1
fi
mkdir -p "$PLUGIN_DIR"
cp -f "$primary_dylib" "$PLUGIN_DIR/$DYLIB_NAME"
echo "[iCloud]   $PLUGIN_DIR/$DYLIB_NAME  <- $primary_source"
echo "           $(lipo -info "$PLUGIN_DIR/$DYLIB_NAME" 2>/dev/null | sed 's/.*: //')"

echo
echo "版本 $VERSION 导出完成：只导出了 $PLUGIN_DIR/$DYLIB_NAME"
