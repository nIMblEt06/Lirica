#!/bin/bash
# Builds "Spotify Wallpaper.app" into build/.
#   ./build.sh            build for this Mac
#   ./build.sh install    build, copy to /Applications and launch
#   ./build.sh release    universal (Apple Silicon + Intel) build, zipped for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
if [[ "$MODE" == "release" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/SpotifyWallpaper"
else
  swift build -c release
  BIN=".build/release/SpotifyWallpaper"
fi

APP="build/Spotify Wallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/web Resources/templates Resources/adapter Resources/AppIcon.icns "$APP/Contents/Resources/"
cp ../CHANGELOG.md "$APP/Contents/Resources/web/ui/CHANGELOG.md"   # shown in What's New
codesign --force --sign - "$APP"
echo "Built $APP"

case "$MODE" in
  install)
    osascript -e 'quit app "Spotify Wallpaper"' 2>/dev/null || true
    pkill -TERM -f "Spotify Wallpaper.app/Contents/MacOS/SpotifyWallpaper" 2>/dev/null || true
    sleep 2
    rm -rf "/Applications/Spotify Wallpaper.app"
    cp -R "$APP" /Applications/
    open "/Applications/Spotify Wallpaper.app"
    echo "Installed to /Applications"
    ;;
  release)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    ZIP="build/Spotify-Wallpaper-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
    ;;
esac
