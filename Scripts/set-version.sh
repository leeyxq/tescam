#!/bin/bash
# 将 MARKETING_VERSION 设为给定 X.Y.Z（不带 v 前缀）。供 CI 发版与本地对齐版本使用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/App/Tescam.xcodeproj/project.pbxproj"
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 1
fi
if [[ ! -f "$PBX" ]]; then
  echo "missing $PBX" >&2
  exit 1
fi

# portable in-place replace (macOS BSD sed + GNU sed)
if sed --version >/dev/null 2>&1; then
  sed -i -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/" "$PBX"
else
  sed -i '' -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/" "$PBX"
fi

grep -n "MARKETING_VERSION" "$PBX"
echo "MARKETING_VERSION -> $VERSION"
