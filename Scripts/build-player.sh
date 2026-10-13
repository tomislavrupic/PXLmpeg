#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build --build-system native -c release --product pxl-player
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app="$root/.build/PXLPlayer.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/pxl-player" "$app/Contents/MacOS/pxl-player"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>pxl-player</string>
  <key>CFBundleIdentifier</key><string>studio.pixelrecords.pxlmpeg.player.research</string>
  <key>CFBundleName</key><string>PXLmpeg Player</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf 'Local development app: %s\n' "$app"
