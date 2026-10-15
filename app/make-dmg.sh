#!/bin/bash
# Packages a built app as a styled disk image:
#   ./make-dmg.sh build/Lirica.app 1.7.1 [build/Lirica-1.7.1.dmg]
#
# The image opens as a 600×464 window (600×400 of content) showing Lirica.app and an Applications
# alias on a background drawn by Tools/dmg_background.swift (retina-aware), with the app's icon
# as the volume icon. The same image is what the app's updater installs from.
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:?usage: make-dmg.sh <Lirica.app> <version> [output.dmg]}"
VERSION="${2:?usage: make-dmg.sh <Lirica.app> <version> [output.dmg]}"
OUT="${3:-build/Lirica-$VERSION.dmg}"
VOLNAME="Lirica"

[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }

WORK=$(mktemp -d)
STAGE="$WORK/stage"
MNT="/Volumes/$VOLNAME"
RW="$WORK/Lirica-rw.dmg"
MOUNTED=""
cleanup() {
  if [[ -n "$MOUNTED" ]]; then hdiutil detach "$MOUNTED" -force -quiet 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# staging: the app, an Applications alias, the background and the volume icon
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Lirica.app"
ln -s /Applications "$STAGE/Applications"
swift Tools/dmg_background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background@2x.png" "$WORK/background.png" \
         -out "$STAGE/.background/background.tiff" >/dev/null
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# writable image, mounted so Finder can lay it out (Finder only sees browsable volumes)
hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
hdiutil create -quiet -ov -format UDRW -fs HFS+ -volname "$VOLNAME" -srcfolder "$STAGE" "$RW"
hdiutil attach "$RW" -quiet -noautoopen
MOUNTED="$MNT"

# volume icon flag (custom icon bit in the volume's Finder info)
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MNT" || true
else
  xattr -wx com.apple.FinderInfo \
    "0000000000000000040000000000000000000000000000000000000000000000" "$MNT" 2>/dev/null || true
fi

# Finder window layout. Finder writes the result to the volume's .DS_Store, so the layout is
# applied before the image is converted; retry a few times in case Finder is slow to see it.
# The window is 600×464 so its content area (the frame minus Finder's 64pt of chrome) is
# 600×400, matching the background. The layout is verified by asking Finder to read it back.
layout() {
  osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Lirica"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 180, 900, 644}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 11
    set background picture of opts to file ".background:background.tiff"
    set position of item "Lirica.app" of container window to {150, 175}
    set position of item "Applications" of container window to {450, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
}

layout_applied() {
  positions=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Finder"
  tell disk "Lirica"
    open
    set p1 to position of item "Lirica.app" of container window
    set p2 to position of item "Applications" of container window
    set result_string to ((item 1 of p1) as string) & "," & ((item 2 of p1) as string) & "|" & ((item 1 of p2) as string) & "," & ((item 2 of p2) as string)
    close
    return result_string
  end tell
end tell
APPLESCRIPT
)
  # Finder can't read the background picture back, so check the .DS_Store bytes for its alias
  if [[ "$positions" == "150,175|450,175" ]] && strings "$MNT/.DS_Store" 2>/dev/null | grep -q "backgroundImageAlias"; then
    echo ok
  else
    echo "positions: $positions"
  fi
}

laid_out=false
check=""
for attempt in 1 2 3; do
  layout || true
  sync
  sleep 1
  check=$(layout_applied || true)
  if [[ "$check" == ok ]]; then laid_out=true; break; fi
  echo "note: Finder layout attempt $attempt didn't stick ($check); retrying" >&2
  sleep 2
done
if [[ "$laid_out" != true ]]; then
  echo "error: Finder didn't keep the window layout ($check)" >&2
  exit 1
fi

# detach, then compress the layout into the shipped image
sync
for attempt in 1 2 3 4 5; do
  if hdiutil detach "$MNT" -quiet 2>/dev/null; then MOUNTED=""; break; fi
  sleep 2
done
if [[ -n "$MOUNTED" ]]; then
  hdiutil detach "$MNT" -force -quiet
  MOUNTED=""
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
hdiutil verify "$OUT" >/dev/null

# final check: mount the shipped image (Finder has to see it to read the layout back out)
hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
hdiutil attach "$OUT" -quiet -noautoopen
if [[ "$(layout_applied || true)" != ok ]]; then
  echo "error: the finished image lost its window layout" >&2
  exit 1
fi
hdiutil detach "$MNT" -quiet
MOUNTED=""

echo "Packaged $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
