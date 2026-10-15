#!/bin/bash
# Builds "Lirica.app" into build/.
#   ./build.sh            build for this Mac
#   ./build.sh install    build, copy to /Applications and launch
#   ./build.sh dmg        build the styled installer disk image
#   ./build.sh release    universal (Apple Silicon + Intel) build, disk image + zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
if [[ "$MODE" == "release" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/SpotifyWallpaper"
  MEDIAREMOTE_BRIDGE=".build/apple/Products/Release/libLiricaMediaRemoteBridge.dylib"
else
  swift build -c release
  BIN=".build/release/SpotifyWallpaper"
  MEDIAREMOTE_BRIDGE=".build/release/libLiricaMediaRemoteBridge.dylib"
fi

APP="build/Lirica.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/web Resources/templates Resources/adapter Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$MEDIAREMOTE_BRIDGE" "$APP/Contents/Resources/adapter/"
cp ../CHANGELOG.md "$APP/Contents/Resources/web/ui/CHANGELOG.md"   # shown in What's New
codesign --force --sign - "$APP/Contents/Resources/adapter/libLiricaMediaRemoteBridge.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"

case "$MODE" in
  install)
    osascript -e 'quit app "Lirica"' 2>/dev/null || true
    pkill -TERM -f "Lirica.app/Contents/MacOS/SpotifyWallpaper" 2>/dev/null || true
    sleep 2
    rm -rf "/Applications/Lirica.app"
    cp -R "$APP" /Applications/
    open "/Applications/Lirica.app"
    echo "Installed to /Applications"
    ;;
  release)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    ZIP="build/Lirica-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # kept for copies of the app that predate DMG updates
    ./make-dmg.sh "$APP" "$VERSION" "build/Lirica-$VERSION.dmg"
    echo "Packaged $ZIP and build/Lirica-$VERSION.dmg"
    ;;
  dmg)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    ./make-dmg.sh "$APP" "$VERSION" "build/Lirica-$VERSION.dmg"
    ;;
esac
