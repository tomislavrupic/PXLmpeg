#!/bin/bash
# Derive the macOS icon family from the checked-in artwork; no third-party tools.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/assets/app-icon/v4}"
mkdir -p "$root/.build"
work="$(mktemp -d "$root/.build/PXLIcon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/PXLmpeg.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$output/PXLmpeg-master.png" --out "$work/PXLmpeg.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$output/PXLmpeg-master.png" --out "$work/PXLmpeg.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/PXLmpeg.iconset" -o "$output/PXLmpeg.icns"
sips -z 1024 1024 "$output/PXLmpeg-master.png" --out "$output/PXLmpeg.png" >/dev/null

if [ -d "$output/PXLmpeg.icon/Assets" ]; then
  cp "$output/PXLmpeg.png" "$output/PXLmpeg.icon/Assets/Monogram.png"
fi
