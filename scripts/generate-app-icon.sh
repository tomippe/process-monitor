#!/bin/bash
# assets/app-icon-source.jpg から AppIcon.icns を生成（ImageMagick + iconutil）
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
SRC="assets/app-icon-source.jpg"
ICONSET="$SCRIPT_DIR/build/AppIcon.iconset"
OUT="$SCRIPT_DIR/AppIcon.icns"
if [ ! -f "$SRC" ]; then
    echo "Missing $SRC"
    exit 1
fi
mkdir -p "$ICONSET"
magick "$SRC" -fuzz 14% -transparent white PNG32:/tmp/process-monitor-master.png
magick /tmp/process-monitor-master.png -resize 1024x1024 -background none -gravity center -extent 1024x1024 PNG32:/tmp/process-monitor-1024.png
for spec in \
    "icon_16x16.png:16" "icon_16x16@2x.png:32" \
    "icon_32x32.png:32" "icon_32x32@2x.png:64" \
    "icon_128x128.png:128" "icon_128x128@2x.png:256" \
    "icon_256x256.png:256" "icon_256x256@2x.png:512" \
    "icon_512x512.png:512" "icon_512x512@2x.png:1024"; do
    name="${spec%%:*}"
    px="${spec##*:}"
    magick /tmp/process-monitor-1024.png -resize "${px}x${px}" "$ICONSET/$name"
done
iconutil -c icns "$ICONSET" -o "$OUT"
echo "OK: $OUT"
