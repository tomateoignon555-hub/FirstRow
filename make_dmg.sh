#!/bin/bash
# Builds First Row and packages it as a drag-to-Applications disk image:  dist/FirstRow-<version>.dmg
# Run it on a Mac (it needs hdiutil and the Xcode command line tools):    bash make_dmg.sh
set -e
cd "$(dirname "$0")"

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "hdiutil not found: run this script on a Mac." >&2
    exit 1
fi

VOL="First Row"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0")
OUT="dist/FirstRow-$VERSION.dmg"
RW="dist/rw-temp.dmg"
STAGE="dist/stage"

echo "==> Building the app"
bash build.sh

echo "==> Preparing the contents of the disk image"
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true   # a leftover mount would rename the new volume
rm -rf dist
mkdir -p "$STAGE/.background"
cp -R "build/First Row.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp dmg/background.png "$STAGE/.background/background.png"
cp Resources/frontrow.icns "$STAGE/.VolumeIcon.icns"
chmod -R go-w "$STAGE"

SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 10240 ))

echo "==> Creating the image"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_KB}k" "$RW" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 2

# custom volume icon (needs SetFile from the command line tools; optional)
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "/Volumes/$VOL" || true
fi

echo "==> Arranging the window (Finder)"
osascript <<APPLESCRIPT || echo "(Finder layout skipped: the image still works, its icons are just not arranged)"
tell application "Finder"
    tell disk "$VOL"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set background picture of opts to file ".background:background.png"
        set position of item "First Row.app" of container window to {150, 215}
        set position of item "Applications" of container window to {450, 215}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 3
chmod -Rf go-w "/Volumes/$VOL" 2>/dev/null || true
for i in 1 2 3 4 5; do
    hdiutil detach "$DEV" >/dev/null 2>&1 && break
    sleep 2
done
hdiutil detach "$DEV" -force >/dev/null 2>&1 || true

echo "==> Compressing"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

echo
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Open it and drag First Row onto Applications."
