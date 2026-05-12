# Process Monitor 紹介ページ設定

## 公開ステータス

**公開済み**（`status: publish`）。

## URL

- 紹介ページ: https://apps.tomippe.jp/process-monitor/
- プライバシーポリシー: https://apps.tomippe.jp/process-monitor/policy/

## WordPress 投稿 ID

| 用途 | ID |
|------|-----|
| 紹介ページ（app） | **2266** |
| プライバシーポリシー（app・子ページ） | 未作成 |

## キャッチフレーズ（app-cp）

メニューバーにCPUトップ
負荷アプリをひと目で

## プラットフォーム

- **platform**: ["mac"]
- **app-macdesc**: macOS 11+, ZIP<br>日本語,English,中文

MAS 公開後は **app-iosurl**（Mac App Store の URL）と **app-macdesc**（`macOS 11+, App Store<br>日本語,English,中文` 形式）を更新すること。

## メディア（WordPress）

| フィールド | メディア ID | 備考 |
|------------|-------------|------|
| app-icon | **2269** | リポジトリ `assets/app-icon-source.jpg`（CPUチップ画像・白背景）。`scripts/generate-app-icon.sh` で `AppIcon.icns` 生成 |
| app-kvbg | **2272** | `kv.jpg`（実体 AVIF）を JPEG 変換してアップロードした KV 画像 |
| app-ss01 | **2271** | `CleanShot 2026-05-11 at 19.22.11.png` をアップロード |
| app-ss01width | **1600** | 表示幅（px）。元画像幅 2116px だが ACF 制約（最大1600）に合わせて設定 |

## KV背景・キー色

- **app-keycolor**: #1e6b4a（基板・ソルダーマスク風のグリーン）
- **app-kvbgaddcss**: `background-repeat` / `center` / `cover` に加え、`background-color: rgba(128, 128, 128, 0.1)` と **`background-blend-mode: luminosity`**（グレー 10% × luminosity）

## 本文（content）

紹介ページ本文は WordPress（投稿 ID 2266）で設定済み。要点:

- 直近 5 分の CPU 平均に基づくメニューバー表示、プロセス一覧・終了・アクティビティモニタ起動
- ローカル集計のみ・外部送信なし
- **多言語 UI**（日本語・English・简体中文、macOS の表示言語に追従）

## バージョン履歴（app-versions）

- 2026.05.11 / v1.0.1 / プロセスメニュー改善、アクティビティモニタ起動追加、アイコン差し替え、紹介ページのKV/スクショ更新
- 2026.05.11 / v1.0.0 / 紹介ページ作成

## ローカル連携

- プロジェクト直下に `.env` を置く（`.env.example` をコピー）。Git には含めない（`.gitignore`）。
- REST API 例: `source ~/.wp-env && source .env` のあと `.env` の投稿 ID を使って取得・更新。
