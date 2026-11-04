#!/bin/bash
# 生成各平台安装包到 dist/：
#   TesCam-<版本>-macOS.dmg          macOS 通用版（Apple 芯片 + Intel），本地签名，未公证
#   TesCam-<版本>-iOS-unsigned.ipa   iOS/iPadOS 未签名包，需用自己的 Apple ID 重签后安装
#   tescam-<版本>-macOS-cli.zip      命令行工具（通用二进制）
# 有 Developer ID 时可设置 SIGN_IDENTITY="Developer ID Application: ..." 并自行公证。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$DIST/.build"
PROJECT="$ROOT/App/Tescam.xcodeproj"
VERSION="$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed -E 's/.*= *([^;]+);/\1/')"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$DIST"
mkdir -p "$BUILD"

echo "==> macOS App $VERSION"
xcodebuild -project "$PROJECT" -scheme Tescam -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$BUILD/mac" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build -quiet
APP="$BUILD/mac/Build/Products/Release/Tescam.app"
codesign --verify --strict "$APP"

STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/TesCam.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "TesCam $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST/TesCam-$VERSION-macOS.dmg"

echo "==> iOS App $VERSION"
xcodebuild -project "$PROJECT" -scheme Tescam -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/ios" \
    CODE_SIGNING_ALLOWED=NO \
    build -quiet
mkdir -p "$BUILD/ipa/Payload"
cp -R "$BUILD/ios/Build/Products/Release-iphoneos/Tescam.app" "$BUILD/ipa/Payload/"
(cd "$BUILD/ipa" && zip -qry "$DIST/TesCam-$VERSION-iOS-unsigned.ipa" Payload)

echo "==> 命令行工具 $VERSION"
swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD/cli" -q
CLI="$(swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD/cli" --show-bin-path)/tescam"
codesign --force --sign - "$CLI"
(cd "$(dirname "$CLI")" && zip -qy "$DIST/tescam-$VERSION-macOS-cli.zip" tescam)

rm -rf "$BUILD"
(cd "$DIST" && shasum -a 256 * > SHA256SUMS.txt)
echo "==> 完成"
ls -lh "$DIST"
