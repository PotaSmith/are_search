## [Planned]

- ドット付き等の特殊フィールドの許容オプションを追加
- 検索のレスポンスデータ削減のための source と fields の設定

## [Unreleased]

## [0.5.0] - 2026-07-22

- `rake_operation_enabled` を追加し、`run_sync_requests` を実行する環境を明示的に限定できるよう変更
- `run_sync_requests` の processing token を固定値にし、rake task が異常中断して token を残した場合も、次回実行で通常同期として再開できるよう変更
- SyncRequest の処理フェーズ、異常中断時の復旧経路、`request_sequence`・`processing_token`・force 処理の役割、古い同期結果を後続のrake通常同期で補正する経路、`retry_count` が増える条件をガイドへ追加
- `request_sequence` の採番処理をproviderへ分離し、PostgreSQL sequenceを使う標準実装を維持しつつ、利用側で継承クラスへ差し替え可能に変更
- More Like This の基準レコードと `mlt_index_target` の対応確認を、モデルクラスの完全一致から Elasticsearch index の一致判定へ変更し、STI 子クラスのレコードを上位モデルの IndexTarget と組み合わせられるよう修正
- 検索結果のActiveRecord復元条件を、`model_includes`・`model_results_where` からモデルごとの `ActiveRecord::Relation` を渡す `model_relations` へ統合。単一targetの `includes`・`results_where` も `relation` へ統合し、Relationの対象クラスは検索対象モデルとの一致を必須化

## [0.4.0] - 2026-07-18

- Elasticsearch index 名を `{index_prefix}__{are_search_ar_table_name}__{target_name}` 形式へ変更し、物理 index の timestamp 前も `__` へ統一。index 名の各要素を小文字英字で始まり、小文字英字とアンダーバーだけを使用する形式に限定。※reindexが必要
- `sort` の Array 形式を廃止し、複数条件は記述順を優先順位とする Hash 形式へ統一
- `aggs` をフィールド名をキーとする Hash 形式へ変更し、各フィールドの `size` を必須化。`AreSearch.default_aggs_size` を削除
- index target単位で flock と marker を取得して処理する `are_search_es_with_index_guard` を追加
- Searchable の継承系統と同一 index 名の所有関係を検査し、STIの検索結果復元を調整
- highlight オプションを整理し、フィールド別設定、`pre_tags`、`post_tags`、`encoder` をそのまま Elasticsearch へ渡すよう変更
- Elasticsearchへ送信するbodyとmappingフィールド名を検査する `EsSearchBodyPolicy` を追加。標準の `ScriptDenyEsSearchBodyPolicy` はscript系キーを拒否し、利用側でpolicyを差し替え可能
- Elasticsearch clientのスレッドキャッシュにPIDを保持し、fork後は親プロセスから継承したclientを再生成
- sync request、index marker、状態確認、reindex、clean up 周辺の排他・復旧処理とテストを整理

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
