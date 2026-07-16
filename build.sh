#!/bin/bash
set -e

# ===== Process Monitor ビルドスクリプト =====
# 直接配布版のみ（Developer ID 署名・ノータライズ・FTP）
# バンドル名: Process Monitor.app / 実行ファイル名: ProcessMonitor

APP_EXE="ProcessMonitor"
APP_BUNDLE_FILE="Process Monitor.app"
BUNDLE_ID="jp.tomippe.processmonitor"
BUILD_DIR="build"
DIST_DIR="../apps.tomippe.jp/process-monitor"
MACOSX_DEPLOYMENT_TARGET="11.0"
MAC_DIST_SLUG="process-monitor"
MAC_DIST_PKG="dmg"
MAC_DIST_MANIFEST_NAME="ProcessMonitor"

DIRECT_BUNDLE="$BUILD_DIR/$APP_BUNDLE_FILE"

SIGNING_IDENTITY="Developer ID Application: TOMIHIDE OTA (4U63Y3X98K)"
KEYCHAIN_PROFILE="TOMIHIDE OTA"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/../build-common/version.sh"
source "$SCRIPT_DIR/../build-common/ftp-upload.sh"
source "$SCRIPT_DIR/../build-common/git-commit.sh"
source "$SCRIPT_DIR/../build-common/mac-sparkle-lib.sh"
source "$SCRIPT_DIR/../build-common/mac-sparkle-dist.sh"

APP_ONLY=false
COMMIT_MSG=""
NO_VERUP=false
while [ $# -gt 0 ]; do
    case "$1" in
        -app) APP_ONLY=true ;;
        -cm) shift; COMMIT_MSG="$1" ;;
        -noverup) NO_VERUP=true ;;
    esac
    shift || true
done

VERSION=$(version_read)

echo "🔨 Process Monitor ($APP_EXE) v$VERSION をビルド中..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

MOVE_SWIFT="$SCRIPT_DIR/../build-common/MoveToApplicationsFolder.swift"
TOMIPPE_ABOUT="$SCRIPT_DIR/../build-common/TomippeAppAbout.swift"
TOMIPPE_RELAUNCH="$SCRIPT_DIR/../build-common/TomippeRelaunch.swift"
TOMIPPE_FEEDBACK="$SCRIPT_DIR/../build-common/TomippeFeedbackForm.swift"
SWIFT_SOURCES="ProcessMonitor.swift $MOVE_SWIFT $TOMIPPE_ABOUT $TOMIPPE_RELAUNCH $TOMIPPE_FEEDBACK"
for src in $SWIFT_SOURCES; do
    if [ ! -f "$src" ]; then
        echo "❌ $src がありません。"
        exit 1
    fi
done
SWIFT_FLAGS="-parse-as-library -framework Cocoa -framework ServiceManagement -F Sparkle.framework/.. -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks"
UNIVERSAL_BIN="$BUILD_DIR/${APP_EXE}_universal"

echo "📦 コンパイル中 (arm64)..."
swiftc -o "$BUILD_DIR/${APP_EXE}_arm64" $SWIFT_FLAGS \
    -target "arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" $SWIFT_SOURCES

echo "📦 コンパイル中 (x86_64)..."
swiftc -o "$BUILD_DIR/${APP_EXE}_x86_64" $SWIFT_FLAGS \
    -target "x86_64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" $SWIFT_SOURCES

echo "📦 Universal Binary を作成中..."
lipo -create \
    "$BUILD_DIR/${APP_EXE}_arm64" \
    "$BUILD_DIR/${APP_EXE}_x86_64" \
    -output "$UNIVERSAL_BIN"

rm "$BUILD_DIR/${APP_EXE}_arm64" "$BUILD_DIR/${APP_EXE}_x86_64"

create_app_bundle() {
    local BUNDLE_PATH="$1"
    local CONTENTS="$BUNDLE_PATH/Contents"
    local MACOS="$CONTENTS/MacOS"
    local RESOURCES="$CONTENTS/Resources"

    mkdir -p "$MACOS" "$RESOURCES"

    cp "$UNIVERSAL_BIN" "$MACOS/$APP_EXE"

    local FRAMEWORKS="$CONTENTS/Frameworks"
    local SPARKLE_REAL
    SPARKLE_REAL="$(readlink -f Sparkle.framework)"
    mkdir -p "$FRAMEWORKS"
    mac_sparkle_embed "$SPARKLE_REAL" "$FRAMEWORKS/Sparkle.framework"

    local ICON_BLOCK=""
    if [ -f "AppIcon.icns" ]; then
        cp "AppIcon.icns" "$RESOURCES/"
        ICON_BLOCK="
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    fi
    if [ -f "$(mac_apps_logo_path)" ]; then
        cp "$(mac_apps_logo_path)" "$RESOURCES/"
    elif [ -f "Resources/AppsLogo.png" ]; then
        cp "Resources/AppsLogo.png" "$RESOURCES/"
    fi

    cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ja</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_EXE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Process Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>Process Monitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOSX_DEPLOYMENT_TARGET</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 tomippe. All rights reserved.</string>
    <key>SUFeedURL</key>
    <string>https://apps.tomippe.jp/process-monitor/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>7jgkjdF0DqNYkF0fUgdoi926jh1HAckFWMdZQreq7HI=</string>${ICON_BLOCK}
</dict>
</plist>
PLIST

    echo -n "APPL????" > "$CONTENTS/PkgInfo"

    for LPROJ in Resources/*.lproj; do
        if [ -d "$LPROJ" ]; then
            local LANG
            LANG=$(basename "$LPROJ")
            mkdir -p "$RESOURCES/$LANG"
            cp "$LPROJ"/* "$RESOURCES/$LANG/"
        fi
    done
}

echo ""
echo "📁 アプリバンドルを作成中 ($APP_BUNDLE_FILE)..."
create_app_bundle "$DIRECT_BUNDLE"

rm -f "$UNIVERSAL_BIN"

if [ -f "AppIcon.icns" ]; then
    echo "🎨 AppIcon.icns を同梱しました"
else
    echo "⚠️  AppIcon.icns がありません"
fi

if $APP_ONLY; then
    echo ""
    echo "🔏 アドホック署名中..."
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$DIRECT_BUNDLE"
    echo ""
    echo "✅ Process Monitor v$VERSION — アプリバンドル作成完了! (-app モード)"
    echo "  open \"$DIRECT_BUNDLE\""
    exit 0
fi

MAC_DIST_BUNDLE_ID="$BUNDLE_ID"
MAC_DIST_PROJECT_ROOT="$SCRIPT_DIR"
MAC_DIST_COMMIT_MSG="$COMMIT_MSG"
mac_sparkle_publish_direct_dist \
    "$DIRECT_BUNDLE" "$BUILD_DIR" "$DIST_DIR" "$VERSION" \
    "$SIGNING_IDENTITY" "$KEYCHAIN_PROFILE" "$APP_BUNDLE_FILE" \
    "$SCRIPT_DIR/Sparkle_bin/generate_appcast"

if ! $NO_VERUP; then
    echo ""
    echo "📝 次回用バージョンを更新しています..."
    version_save_next "$VERSION"
fi

git_commit_build "$VERSION" "$COMMIT_MSG"

echo ""
echo "✅ Process Monitor v$VERSION — ビルド・配布完了!"
echo "  $MAC_DIST_OUTPUT_PATH"
echo ""
