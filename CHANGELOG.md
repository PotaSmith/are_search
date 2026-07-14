## Planned

- reindex等と同等のロックをするバッチ処理用のAPI
- ドット付き等の特殊フィールドの許容オプションを追加
- 検索データ削減のためのsource と fields の設定

## [Unreleased]

## [0.3.1] - 2026-07-14

- index削減のための、mapping の sourceと includes の設定。※reindexが必要

## [0.3.0] - 2026-07-14

- 検索処理を AreSearch::Searcher に統合し、旧検索クラスを削除
- 検索オプションの定義と検証処理を再構成
- where / where_not / where_or を term / terms / range を明示する形式へ変更
- fields、sort、aggs、highlight などの検索パラメーター形式を変更

## [0.2.0] - 2026-07-11

- 大量の修正。reindexが必要
- IndexTargetとtarget別mappingsの整備
- alias・物理index・marker・flockを使ったreindex運用
- 全index reindexや状態確認などのrakeタスク
- 単一検索のMultiSearch統合
- RawSearchのbuild_model_bool
- MoreLikeThisのオプション追加
- highlightとSearchResultの拡張
- max_result_windowに基づくページング制限
- mapping/data検証と予約フィールド
- STI対応

## [0.1.3] - 2026-07-09

- docsの整理

## [0.1.2] - 2026-07-08

- index_settings の設定方法の変更

## [0.1.1] - 2026-07-08

- releaseテスト

## [0.1.0] - 2026-05-16

- Initial release
