#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/.build/site"
mkdir -p "$output/assets"
cp "$root/site/index.html" "$root/site/styles.css" "$root/site/site.js" "$output/"
cp "$root/assets/pxlmpeg-signal-flow-v2.png" "$output/assets/pxlmpeg-signal-flow-v2.png"
cp "$root/assets/app-icon/v5/PXLmpeg.png" "$output/assets/pxlmpeg-icon.png"
cp "$root/site/pxlmpeg-icon-64.png" "$root/site/pxlmpeg-icon-256.png" "$output/assets/"
printf 'PXLmpeg site prepared at %s\n' "$output"
