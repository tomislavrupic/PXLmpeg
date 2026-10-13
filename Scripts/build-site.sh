#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/.build/site"
mkdir -p "$output/assets"
cp "$root/site/index.html" "$root/site/styles.css" "$root/site/site.js" "$root/site/favicon.svg" "$output/"
cp "$root/assets/pxlmpeg-banner-v1.png" "$output/assets/pxlmpeg-banner-v1.png"
printf 'PXLmpeg site prepared at %s\n' "$output"
