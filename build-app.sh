#!/bin/bash
# Builds "to HEIF.app". No Xcode project needed — swiftc plus a hand-assembled bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="build.noindex/to HEIF.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Built for both architectures so the bundle also runs on Intel Macs.
mkdir -p build.noindex/slices
for ARCH in arm64 x86_64; do
  swiftc \
    -swift-version 5 \
    -target "$ARCH-apple-macosx15.0" \
    -sdk "$SDK" \
    -O \
    -framework SwiftUI -framework Photos -framework AppKit \
    -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers \
    -o "build.noindex/slices/jpg2heif-$ARCH" \
    Sources/ConversionKit/*.swift \
    App/Sources/*.swift
done
lipo -create build.noindex/slices/jpg2heif-arm64 build.noindex/slices/jpg2heif-x86_64 \
     -output "$APP/Contents/MacOS/jpg2heif"

cp App/Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: every size is drawn fresh rather than scaled, so 16pt stays legible.
ICONSET="build.noindex/jpg2heif.iconset"
rm -rf "$ICONSET"
swiftc -O -o build.noindex/makeicon Tools/makeicon.swift
./build.noindex/makeicon App/Resources/logo.png "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. TCC keys on the bundle id plus this signature, so a rebuild
# can make macOS ask for photo access again.
codesign --force --sign - \
  --entitlements App/jpg2heif.entitlements \
  --options runtime \
  "$APP"

echo "built $APP"
