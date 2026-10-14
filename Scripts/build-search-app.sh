#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build --build-system native -c release --product pxl-search-app
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app="$root/.build/PXLSearch.app"
staging_root="$(mktemp -d "$root/.build/PXLSearch.stage.XXXXXX")"
staged_app="$staging_root/PXLSearch.app"
backup=""
cleanup() {
  if [ -n "$backup" ] && [ ! -e "$app" ] && [ -d "$backup/PXLSearch.app" ]; then
    mv "$backup/PXLSearch.app" "$app"
  fi
  rm -rf "$staging_root"
}
trap cleanup EXIT
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$root/assets/app-icon/PXLmpeg.icns" "$staged_app/Contents/Resources/PXLmpeg.icns"
cp "$binary_dir/pxl-search-app" "$staged_app/Contents/MacOS/pxl-search-app"
cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>pxl-search-app</string>
  <key>CFBundleIdentifier</key><string>studio.pixelrecords.pxlmpeg.search.research</string>
  <key>CFBundleIconFile</key><string>PXLmpeg</string>
  <key>CFBundleDisplayName</key><string>PXLmpeg Search</string>
  <key>NSHumanReadableCopyright</key><string>Pixel Records · Early research</string>
  <key>CFBundleName</key><string>PXLmpeg Search</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.8.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# External developer cache location, not bundled model weights. Optional override is a folder.
model_path="${1:-$root/.work/semantic/models}"
if [ -f "$model_path/download-manifest.json" ]; then
  model_path="$(cd "$model_path" && pwd)"
  /usr/libexec/PlistBuddy -c "Add :PXLDefaultModelDirectory string $model_path" "$staged_app/Contents/Info.plist"
fi
codesign --force --sign - "$staged_app"
codesign --verify --strict "$staged_app"
if [ -e "$app" ]; then
  backup="$(mktemp -d "$root/.build/PXLSearch.previous.XXXXXX")"
  mv "$app" "$backup/PXLSearch.app"
fi
mv "$staged_app" "$app"
if [ -n "$backup" ]; then printf 'Previous app preserved at: %s\n' "$backup/PXLSearch.app"; fi
printf 'Development app: %s\n' "$app"
