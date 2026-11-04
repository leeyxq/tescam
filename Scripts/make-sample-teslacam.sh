#!/usr/bin/env bash
# 用 ffmpeg 生成一个模拟的 TeslaCam U 盘目录（无 SEI 车辆数据），用于本地调试。
# 用法：Scripts/make-sample-teslacam.sh <输出目录> [每段秒数]
set -euo pipefail
OUT="${1:?用法: $0 <输出目录> [每段秒数]}"
SECONDS_PER_CLIP="${2:-10}"
CAMS=(front back left_repeater right_repeater)
COLORS=(0x1f6feb 0x8957e5 0x2ea043 0xd29922)

clip() { # $1=目录 $2=时间戳 $3=序号
  for i in "${!CAMS[@]}"; do
    ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1280x960:rate=36:duration=${SECONDS_PER_CLIP}" \
      -f lavfi -i "color=c=${COLORS[$i]}:size=1280x960:rate=36:duration=${SECONDS_PER_CLIP}" \
      -filter_complex "[0][1]blend=all_mode=overlay" \
      -c:v libx264 -pix_fmt yuv420p "$1/$2-${CAMS[$i]}.mp4"
  done
}

mkdir -p "$OUT/TeslaCam/RecentClips" "$OUT/TeslaCam/SavedClips/2025-06-01_09-00-15" "$OUT/TeslaCam/SentryClips/2025-06-01_21-30-08"
clip "$OUT/TeslaCam/RecentClips" 2025-06-01_08-30-00
clip "$OUT/TeslaCam/RecentClips" 2025-06-01_08-30-10
clip "$OUT/TeslaCam/SavedClips/2025-06-01_09-00-15" 2025-06-01_09-00-05
cat > "$OUT/TeslaCam/SavedClips/2025-06-01_09-00-15/event.json" <<JSON
{"timestamp":"2025-06-01T09:00:12","city":"上海市","est_lat":"31.2304","est_lon":"121.4737","reason":"user_interaction_honk","camera":"0"}
JSON
clip "$OUT/TeslaCam/SentryClips/2025-06-01_21-30-08" 2025-06-01_21-30-00
cat > "$OUT/TeslaCam/SentryClips/2025-06-01_21-30-08/event.json" <<JSON
{"timestamp":"2025-06-01T21:30:05","city":"上海市","est_lat":"31.2310","est_lon":"121.4740","reason":"sentry_aware_object_detection","camera":"5"}
JSON
echo "已生成：$OUT/TeslaCam"
