#!/bin/bash
# 自动签名并安装到 USB 连接的 iPhone/iPad，然后启动
# 用法：Scripts/run-device.sh [设备UDID]
# 可用环境变量覆盖：TEAM_ID、BUNDLE_ID
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-25YH95S897}"
BUNDLE_ID="${BUNDLE_ID:-com.leeyxq.tescam}"
DERIVED=.build/device
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /[[:space:]](connected|available)[[:space:]]/ && /\((iPhone|iPad)[0-9]/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}"
[ -n "$DEVICE" ] || { echo "未找到已连接的 iPhone/iPad"; exit 1; }
echo "设备：$DEVICE"

xcodebuild -project App/Tescam.xcodeproj -scheme Tescam -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
  build -quiet

xcrun devicectl device install app --device "$DEVICE" "$DERIVED/Build/Products/Debug-iphoneos/Tescam.app"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" \
  || echo "启动失败：首次安装请在手机 设置 › 通用 › VPN与设备管理 中信任开发者证书后重试"
