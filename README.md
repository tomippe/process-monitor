# Process Monitor

macOS メニューバーに、直近5分間の平均 CPU 使用率が最も高いプロセス名と平均%を表示するアプリ。

## 機能

- メニューバーに CPU アイコンとトッププロセスの平均 CPU 使用率を表示
- 10 秒ごとにサンプリングし、直近 5 分間の平均で集計
- クリックメニューから:
  - **1〜20位のランキング** — 各項目のサブメニューで CPU 時間・停止など
  - **状況をコピー** (⌘C)、**今すぐ更新** (⌘R)、**アクティビティモニタを起動**
  - **終了** (⌘Q)
- 日本語・英語・簡体中国語 UI（macOS の優先言語に追従）
- Dock に表示されないメニューバー専用アプリ

## 動作環境

- macOS 11 (Big Sur) 以降
- Intel / Apple Silicon 両対応

## アプリアイコン

オリジナル画像は `assets/app-icon-source.jpg`（白背景＋ティール系）。ルートの `AppIcon.icns` は次で再生成できます。

```bash
./scripts/generate-app-icon.sh
```

## インストール

### 方法 1: ビルドスクリプト（推奨）

```bash
./build.sh -app
```

成果物は **`build/Process Monitor.app`**（実行ファイル名は `ProcessMonitor`、Universal Binary・`-app` 時はアドホック署名）。そのままコピーして使うか、`open "build/Process Monitor.app"` で起動できます。

### 方法 2: インストーラー（~/Applications へ）

```bash
./install.command
```

`~/Applications/Process Monitor.app` にインストールされ、自動で起動します（`./build.sh -app` の成果物をコピーします）。

## ログイン時の自動起動

システム設定 → 一般 → ログイン項目 → **Process Monitor.app** を追加（macOS 13+ はアプリ内メニュー「ログイン時に起動」でも設定可）

## 技術仕様

| 項目 | 内容 |
|------|------|
| 言語 | Swift |
| フレームワーク | Cocoa (AppKit) |
| CPU 取得 | `/bin/ps` と `NSRunningApplication`（アイコン表示に `proc_pidpath` 等） |
| サンプリング間隔 | 10 秒 |
| 集計範囲 | 直近 300 秒（5 分） |
| 外部依存 | なし |

## 制作情報

- 制作: PINK RAVEN (pinkraven.net)
- 制作日: 2026-05-11
- ライセンス: [MIT License](LICENSE) — 利用・改変・再配布を自由に行えます（著作権表示とライセンス文の保持が条件です）。
