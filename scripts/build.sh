#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# --no-install only assembles build/Screengrab.app, for scripts/release.sh.
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0
BUNDLE_ID=io.github.florianriquelme.screengrab
VERSION=${VERSION:-0.0.0-dev}

APP=build/Screengrab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Command Line Tools cannot build multi-arch in one go, so build each slice and lipo them.
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx26.0"
    cp "$(swift build -c release --triple "$arch-apple-macosx26.0" --show-bin-path)/Screengrab" "build/Screengrab-$arch"
done
lipo -create build/Screengrab-arm64 build/Screengrab-x86_64 -output "$APP/Contents/MacOS/Screengrab"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Screengrab</string>
    <key>CFBundleExecutable</key><string>Screengrab</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>Screengrab shows your camera in a bubble that appears in screen recordings.</string>
    <key>NSMicrophoneUsageDescription</key><string>Screengrab records your microphone with screen recordings.</string>
</dict>
</plist>
PLIST

# The local identity keeps privacy grants across rebuilds; ad-hoc signing resets them every build.
IDENTITY=$(security find-identity -p codesigning | awk -F'"' '/"Screengrab Local Signing"/ {print $2; exit}')
codesign --force --deep -s "${IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"

[[ $INSTALL == 1 ]] || exit 0

pkill -x Screengrab || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Screengrab.app"
ditto "$APP" "$HOME/Applications/Screengrab.app"
echo "Installed ~/Applications/Screengrab.app"
