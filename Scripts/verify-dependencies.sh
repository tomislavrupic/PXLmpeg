#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .work
swift package dump-package > .work/package-audit.json
xcrun swift Scripts/audit-manifest.swift .work/package-audit.json
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
for product in pxlmpeg pxl-player pxl-search pxl-search-app; do
  report=".work/$product-runtime-dependencies.txt"
  otool -L "$binary_dir/$product" > "$report"
  awk 'NR>1 {print $1}' "$report" | while IFS= read -r library; do
    case "$library" in /System/Library/*|/usr/lib/*|@rpath/libswift*) ;; *) echo "Unexpected runtime dependency: $library" >&2; exit 1;; esac
  done
done
printf 'Runtime: CLI, player, semantic prototype and native search app use Apple system frameworks and Swift libraries only\n'
