#!/bin/bash
# Wraps the SwiftPM binary in a .app bundle so it behaves like a normal Mac app
# (Dock icon, menu bar, file dialogs). No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Hexeon"
APP="build/Hexeon.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hexeon"

# SwiftPM puts resources in a side-car bundle; Bundle.module needs it alongside
# the executable, so carry it into the app.
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
for RESOURCE in "$BUILD_DIR"/*.bundle; do
  [ -e "$RESOURCE" ] && cp -R "$RESOURCE" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hexeon</string>
  <key>CFBundleDisplayName</key><string>Hexeon</string>
  <key>CFBundleIdentifier</key><string>dev.local.hexeon</string>
  <key>CFBundleExecutable</key><string>Hexeon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

# Copied resources carry xattrs (quarantine, provenance) that codesign rejects.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"
echo "built $APP"
