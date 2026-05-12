#!/bin/bash
# ProcessMonitor インストーラー（build.sh の成果物を ~/Applications に配置）
# 使い方: ./install.command をダブルクリック、または bash install.command

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_BUNDLE_FILE="Process Monitor.app"
APP_DIR="$HOME/Applications"
APP_PATH="$APP_DIR/$APP_BUNDLE_FILE"
BUILT_APP="$SCRIPT_DIR/build/$APP_BUNDLE_FILE"

echo "======================================"
echo " Process Monitor インストーラー"
echo "======================================"
echo ""
echo " macOS メニューバーに直近5分平均CPUトップのプロセスを表示します"
echo ""

if ! xcode-select -p &>/dev/null; then
    echo "[INFO] Xcode Command Line Tools をインストールします..."
    xcode-select --install
    echo "[INFO] インストール完了後、もう一度このスクリプトを実行してください。"
    exit 0
fi

echo "[INFO] ビルド中（./build.sh -app）..."
./build.sh -app

if [ ! -d "$BUILT_APP" ]; then
    echo "[ERROR] ビルド成果物が見つかりません: $BUILT_APP"
    exit 1
fi

mkdir -p "$APP_DIR"
rm -rf "$APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"

echo "[SUCCESS] インストール完了!"
echo "  場所: $APP_PATH"
echo ""

read -p "ログイン時に自動起動しますか？ (y/n): " autostart
if [[ "$autostart" == "y" || "$autostart" == "Y" ]]; then
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_PATH\", hidden:false}" 2>/dev/null && \
    echo "[SUCCESS] ログイン項目に追加しました。" || \
    echo "[INFO] 手動で追加: システム設定 → 一般 → ログイン項目"
fi

echo ""
echo "起動します..."
open "$APP_PATH"
