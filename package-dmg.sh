#!/bin/bash
# Packages the built app into a DMG for handing to someone else.
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "build.noindex/to HEIF.app/Contents/Info.plist")
DMG="build.noindex/to HEIF-$VERSION.dmg"
STAGE="build.noindex/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build.noindex/to HEIF.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The app is ad-hoc signed, so every recipient has to clear the quarantine flag
# macOS sets on downloads. Ship the instructions inside the disk image.
cat > "$STAGE/请先阅读.txt" <<'TXT'
安装方法

1. 把「to HEIF」拖到旁边的「Applications」文件夹。

2. 打开「终端」，粘贴下面这行并回车：

   xattr -dr com.apple.quarantine "/Applications/to HEIF.app"

3. 现在可以正常打开了。首次启动会请求访问「照片」，请点允许。


为什么需要第 2 步？

这个 App 没有用 Apple 开发者证书签名，也没有经过公证。macOS 会给所有从网上
下载的文件打上隔离标记，对未公证的 App 直接拒绝打开，提示「已损坏」。
第 2 步就是移除这个标记。

系统要求：macOS 15 或更高。Intel 和 Apple 芯片都支持。
TXT

hdiutil create -volname "to HEIF" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "打包完成: $DMG"
ls -lh "$DMG" | awk '{print "  大小:", $5}'
