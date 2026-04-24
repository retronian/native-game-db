# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

日本語で会話すること。

## プロジェクト概要

レトロゲームのネイティブスクリプト（ひらがな・カタカナ・漢字等、非ラテン文字の本来の表記）対応ゲームデータベース。個別 JSON ファイルを Ruby スクリプトで加工し、GitHub Pages に静的 API / HTML として配信する。サイト: https://gamedb.retronian.com/

## 主要コマンド

### ビルド

```bash
ruby scripts/build_api.rb
```

`data/games/` から `dist/` に JSON API（`/api/v1/...`）と HTML ビューを生成する。push to main で GitHub Actions が同じコマンドを実行し、GitHub Pages にデプロイ。

### データパイプライン（通常この順）

1. `ruby scripts/fetch_wikidata.rb [platform]` — Wikidata SPARQL から多言語タイトルを seed
2. `ruby scripts/fetch_igdb.rb --search` — IGDB で external_id 解決 + `game_localizations` 補完
3. `ruby scripts/merge_romu.rb` / `scripts/merge_skyscraper_ja.rb` / `scripts/merge_gamelist_ja.rb` — 兄弟リポジトリのキュレート済み日本語データをマージ
4. `ruby scripts/merge_no_intro.rb` — No-Intro DAT から ROM メタデータ（hash / serial / size）
5. `ruby scripts/dedupe.rb` — 同一 external_id の重複除去
6. `ruby scripts/fetch_covers.rb` — libretro-thumbnails からカバーアート URL（ROM 名完全一致）
7. `ruby scripts/fetch_jp_covers.rb` — JP 版 boxart の二次パス。libretro-thumbnails の romaji 日本語ファイル名 (例: "Chocobo no Fushigi na Dungeon 2") を slug + ampersand/hyphen 緩和マッチ。`data/media_aliases.json` の手動エイリアスも参照
8. `ruby scripts/fetch_wikipedia_covers.rb` — 三次パス。libretro にも無い JP boxart を Wikipedia REST v1 `/page/summary` 経由で取得 (Wikidata QID から ja/en 記事をサイトリンクで解決)。fair-use boxart も拾える
9. `ruby scripts/import_local_media.rb` — `media/` ディレクトリにドロップされた手動収集画像を取り込み
10. `ruby scripts/ingest_issue.rb <issue#>` — GitHub Issue (`[media]` / `[title]`) を取り込み。添付画像のダウンロード → `media/` 配置 → `import_local_media.rb` 実行まで自動。タイトル投稿は `titles[]` に直接追加
11. `ruby scripts/fetch_descriptions.rb` / `scripts/fetch_wikipedia_extracts.rb` — Wikipedia 概要文

### コミュニティ貢献フロー

1. ゲームページの「⚡ Help complete this entry」セクションから、欠けているデータ (JP/KR/CN 版 boxart・ネイティブタイトル) ごとのリンクをクリック
2. GitHub Issue フォーム (`.github/ISSUE_TEMPLATE/media-submission.yml` / `title-submission.yml`) が必須項目事前入力で開く (平台・ゲーム ID・種類・リージョン)
3. 投稿者は画像添付 + 出典を記入して送信
4. メンテナは `ruby scripts/ingest_issue.rb <issue#>` で一発取り込み → commit / push
5. テンプレートは EN / JA / KO / ZH 4 言語併記

スキーマ検証は `scripts/Gemfile` の `json-schema` gem が実施。

### 依存

- Ruby 3.3+
- `gh` CLI（libretro-thumbnails アート取得用、サインイン要）
- Twitch/IGDB API credentials（任意、augmentation 時のみ）

## アーキテクチャ

**スタック:** Ruby スクリプト + 個別 JSON ファイル + GitHub Pages 静的配信。従来型のビルドシステムは持たない。

**データフロー:** Wikidata seed → IGDB / No-Intro / Wikipedia / 兄弟リポジトリで augment → covers で enrich → `build_api.rb` で static API 生成 → GitHub Actions で deploy。

**重要ディレクトリ:**

- `data/games/{platform}/{id}.json` — canonical データストア（1 ゲーム = 1 ファイル）
- `schema/game.schema.json` — 権威あるスキーマ。データ変更はこれに準拠
- `scripts/` — fetch / merge / dedupe / build の Ruby スクリプト群
- `scripts/lib/` — 共有ユーティリティ（`script_detector.rb` がテキストから `Jpan` / `Hira` / `Kana` を判定、`slug.rb`, `db_index.rb`）
- `dist/` — ビルド出力（gitignore）

**兄弟リポジトリ依存:** merge スクリプトは作業ディレクトリの親に以下が存在することを期待する。

- `../romu` — ROM collection manager のキュレート gamedb
- `../no-intro-dat` — No-Intro DAT ファイル群
- `../gamelist-ja` — 日本語 gamelist.xml データ
- `../skyscraper-ja` — Skyscraper キャッシュの SHA1→日本語タイトル

## データモデル

`titles[]` は以下の 7 軸を持つ。**`script` がこのプロジェクト固有のコア識別軸**で、他の DB にはない。

- `text` — タイトル文字列
- `lang` — ISO 639-1（`ja` / `en` / `ko` / `zh` / ...）
- `script` — **ISO 15924**（`Jpan`=漢字混じり / `Hira`=ひらがなのみ / `Kana`=カタカナのみ / `Hang` / `Hans` / `Hant` / `Latn`）
- `region` — ISO 3166-1 小文字（`jp` / `us` / `eu` / `kr` / ...）
- `form` — `official` / `boxart` / `ingame_logo` / `manual` / `romaji_transliteration` / `alternate`
- `source` — `wikidata` / `igdb` / `mobygames` / `screenscraper` / `no_intro` / `community` / `manual`
- `verified` — 一次ソース（タイトル画面・オリジナルパッケージ）で確認済みか

region（リリース地域）と lang（箱・画面上の言語）は**独立した軸**として扱う。混ぜない。

**スラッグ規約:** lowercase ASCII + ハイフン（例: `hoshi-no-kirby`）。ファイル名 `{id}.json` と一致させる。

**手動修正:** `data/games/{platform}/{id}.json` を直接編集する surgical change を推奨。

## ライセンス / スコープ

- **コード** (`scripts/`, `.github/`, `schema/`) — MIT
- **データ** (`data/games/`, 公開 JSON API, HTML) — CC BY-SA 4.0（Wikipedia 由来のため）

**商用リリース版のみ収録。** プロトタイプ / ベータ / ホームブリュー / ハック / アフターマーケット品は意図的に除外。`roms[]` に retail ROM が 1 つ以上ある場合のみ残る。

**IGDB / MobyGames / GameFAQs は TOS 上バルク取り込み不可。** `fetch_igdb.rb` は external_id 解決と `game_localizations` 補完のみ使い、ペイロードの再配布はしない。

## 背景・動機

- 既存の主要スクレイパー（Skyscraper, ES-DE等）が接続するDB（ScreenScraper.fr, TheGamesDB）は、日本語リージョンを指定してもローマ字しか返さない
- IGDB、Wikidata、MobyGames にはネイティブスクリプトのデータが散在するが、レトロゲームROM管理用スクレイパーと統合されたものは存在しない
- 「日本人が一般的なツールで、自分のROMコレクションに日本語ネイティブスクリプトの情報を設定する」方法が現状ない

## 既存調査結果

### スクレイパー × DB のネイティブスクリプト対応状況

| DB | スクレイパー連携 | ネイティブスクリプト |
|---|---|---|
| ScreenScraper.fr | Skyscraper, ES-DE | ❌ ローマ字のみ |
| TheGamesDB | ES-DE | ❌ 証拠なし |
| IGDB | RomM, Playnite | ⚠️ `game_localizations` にあるがカバレッジ不明 |
| Wikidata | なし | ✅ SPARQLで取得可（`星のカービィ`等 確認済み） |
| MobyGames | なし（レトロ向け） | ⚠️ `alternate_titles` に設計上あり |
| GameTDB | なし | ✅ だがFC/SFC/GB/GBA/MD非対応 |
| OpenVGDB | なし | ❌ 不明 |

### DB構築方法の業界標準

- 全主要DB（ScreenScraper, MobyGames, IGDB, TheGamesDB等）はコミュニティ手動入力
- パターン: 初期シードデータ + ユーザーWebUI投稿 + モデレーター承認制
- ライセンス的にオープンに再利用可能なのは OpenVGDB（MIT）のみ

### 初期データ構築戦略

1. **Wikidata SPARQL** でレトロ全般の日本語名を一括取得（No-Intro英語名→日本語名マッピング）
2. **IGDB** の `game_localizations` で補完
3. 足りないものはコミュニティ投稿で埋める

## 関連プロジェクト

- **retronian/romu** — ROM collection manager。scan → match → enrich → export-gamelist。内蔵gamedbをgo:embedする方式。Retronian GameDBのデータをromuが消費する関係になりうる
- **komagata/gamelist-ja** — 既存の日本語gamelist.xml生成ツール。Retronian GameDBの前身的位置づけ
- **komagata/skyscraper-ja** — Skyscraperキャッシュへの日本語インポート
- **retronian/OneOS** — MinUIフォークの日本語対応CFW。ネイティブスクリプト表示の消費者

## 用語

- **ネイティブスクリプト (native script)**: マルチバイト文字の本来の表記。ローマ字（romaji）と対比して使う。日本語なら「星のカービィ」、韓国語なら한글表記、中国語なら漢字表記
