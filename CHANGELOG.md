## [Planned]

- ドット付き等の特殊フィールドの許容オプションを追加

## [Unreleased]

- 外部入力として扱う検索値を検査する `search_param_policy` を追加。`SearchParamPolicy` 継承クラスへ差し替え可能に変更
- BulkIndexer の recover 正常終了時に、通常実行側の失敗結果とrecover側の結果を世代ディレクトリへ退避し、次回recoverで過去の結果ファイルを再読込しないよう変更
- More Like This の基準情報を mlt.like にまとめ、instance と index_target を指定する形へ整理。
- mlt.fields の検索対象と基準を _source または store: true から取得可能であることも検証するように修正
- force sync・reindex の bulk response の検証を追加
- ページネーションを `max_result_window` の範囲に合わせて整理。開始位置が `max_result_window` 以上になる検索は実行前に検索パラメータ不正として扱うよう変更
- 検索結果の件数を `es_total_count`、`total_count`、`pagination_total_count` に分離。
- BulkIndexer と Reindexer の実処理入口で、Searchable を継承した STI 子クラスの IndexTarget を拒否するよう変更。共有 alias へ子クラスのレコードだけを投入して完了扱いになる経路と、Reindexer の直接呼び出しで公開APIのガードを迂回する経路を防止
- `are_search_index_data` の戻り値を直接変更せず、複製した Hash へ AreSearch の予約フィールドを追加するよう変更。freeze 済みまたは再利用する Hash でも呼び出し側データを汚染しないよう修正
- Elasticsearch client 作成時のデバッグログで、接続先情報だけを出力し、`user` / `password` などの認証情報を含めないよう変更
- sync limit alert メールから `last_error` 本文を除外。`last_error_at` と通知条件は維持し、エラー詳細は `are_search_sync_requests` で確認する形へ変更
- Elasticsearch の alias と物理 index の判定を整理。`EsAdapter#index_alias_exists?` で alias 存在確認を boolean として扱い、alias 名と同名の物理 index 判定では通常 alias を物理 index と誤認しないよう修正。重複していた `IndexManager#index_alias_exists?` を削除して判定を `EsAdapter` へ統一
- 検索結果取得用の `response.stored_fields` と `response.docvalue_fields` を追加。Elasticsearch の `stored_fields` / `docvalue_fields` へ String 配列を渡し、取得値を既存の `records_with_hit` の `hit[:fields]` から参照できるよう変更
- `response.fields` は通常 field の値を `_source` から取得するため、`store: true` だけでは取得できないことをガイドへ明記。`stored_fields`、`docvalue_fields`、runtime field との取得経路の違いを整理

## [0.8.0] - 2026-08-08

- このバージョンは、reindex、DB、jobの作り直しが必要だが、バージョンが1.0.0以下なので移行手順は用意しない
- 命名の大幅な整理
- 大規模データを既存aliasへ容量・件数上限付きで投入する `BulkIndexer` を追加。checkpointによる中断再開、失敗IDのrecover、永続ディレクトリへの結果記録、実行用Ruby/shellサンプルgeneratorを追加
- 新しいIndexTargetをBulkIndexerで構築するため、Elasticsearch上に空の物理indexを作成してaliasを接続する `IndexTarget#are_search_create_index` を追加。既存aliasとSearchable継承子クラスからの実行を拒否
- BulkIndexer実行時に対象IndexTargetのalias存在を確認し、未作成indexへのbulk投入を開始しないよう変更

- `index_prefix`、`are_search_ar_table_name`、`index_target_name`、mappingsのフィールド名、`sync_stage_name` の名前検査を共通化し、小文字英数字の単語を単一のアンダーバーで区切る形式へ変更。`index_prefix` の空文字列指定を廃止し、`are_search_index_mappings` 内の全Hash keyをSymbol必須として検査するよう整理
- sync request を `IndexTarget × sync_stage_name` 単位へ変更し、全stageを定義する `are_search_all_sync_stage_names`、保存時に要求を作る `are_search_sync_stage_names_on_enqueue`、commit後に開始する `are_search_sync_stage_names_on_after_commit` を追加。`are_search_index_data` は `index_target_name` と `sync_stage_name` を受け取るよう変更
- reindex は `are_search_all_sync_stage_names` の先頭または末尾を `stage_position: :first` / `:last` で明示して実行し、`run_sync_requests` は処理対象のstage名を引数で指定するよう変更
- reindex、clean up、index guard の戻り値を、成否・失敗理由・停止段階・完了段階を持つHashへ統一。alias更新APIがaction失敗を返した場合は例外にせず失敗結果として返すよう変更
- Searchable を継承した子クラスからのreindexを拒否し、独立した継承系統の上位モデル間で同じElasticsearch aliasが重複する場合は全reindexを開始しないよう変更
- 同期試行回数の命名を整理し、`max_retry_count` を `max_sync_try_count`、`force_attempt_count` を `force_try_count`、`force_attempted_at` を `last_force_try_at`、`max_force_attempt_count` を `max_force_try_count` へ変更
- `request_sequence_provider` と `RequestSequenceProvider` を、DB固有処理の差し替え口となる `database_specific` と `DatabaseSpecific` へ変更し、同期要求の採番とupsertを `PostgreSQLDatabaseSpecific` へ統合
- 検索時の `runtime_mappings` を追加。検索実行時は `enable_runtime_mappings: true` 指定時以外は例外
- `response.fields` を追加し、Elasticsearchの `fields` へString配列を渡せるよう変更。検索結果の `records_with_hit` に `fields` を追加
- 標準検索に `response.source` を追加。検索結果の `_source` は既定でActiveRecord復元用の予約フィールドだけに限定し、利用側がStringのsource pathを追加指定できるよう変更
- 外部入力として使用する `queries.query_string`、where系の条件値、`page` が不正な場合、`search_failure_mode` に従って `STATUS_PARAMS_INVALID` の空結果を返すか `InvalidSearchOption` を送出するよう変更
- `aggs` にフィールド配列の簡易形式を追加し、既定のbucket数を返す `AreSearch.default_aggs_size` を追加。その値を使用したterms aggregationへ変換するよう変更。Hash形式はfieldを持つElasticsearch aggregation形式へ統一し、aggregation種別を限定せずfieldだけをmappingと照合するよう整理
- `highlight` はfieldsの簡易形式とフィールド検査を維持し、fields以外とフィールド別オプションは変更せずElasticsearchへ渡すよう整理
- `mlt` はinstance、index_target、fieldsの検査を維持し、その他のパラメーターは値の型を限定せずElasticsearchへ渡すよう変更

## [0.7.0] - 2026-07-31

- 標準検索オプションのフィールド判定を `properties` 直下に限定し、`runtime` は正式な対応対象外とした
- `SearchResult#highlights`、`SearchResult#hit_source`、`records_with_index_target_names` を廃止し、各レコードと対応する `_index`、`_id`、`_source`、highlight、index_target_name を検索順で返す `records_with_hit` へ統合
- `SearchResult#aggs` を、集計名指定時は表示用キー、省略時は内部キーの簡易集計結果を返すメソッドへ変更。`key` がある bucket は `[key, doc_count]`、ない bucket は `doc_count` として返す
- `Searcher.search` の標準検索オプションを `queries` に統一し、トップレベルの `query_string`、`fields`、`query_type` を廃止。`IndexTarget#are_search_search` の引数は維持し、内部で1件の `queries` へ変換するよう変更
- `AreSearch.multi_search` と `AreSearch.more_like_this` を削除し、複数 target 検索と More Like This 検索の入口を `Searcher.search` へ統一

## [0.6.0] - 2026-07-29

- More Like This の `mlt_instance`、`mlt_index_target`、`mlt_params` を廃止し、基準情報と検索パラメーターを `mlt` Hash へ統合
- More Like This の `fields` が、検索対象だけでなく基準レコードの `mlt.index_target` にも text 型または keyword 型として存在することを検証するよう変更
- 全文検索方式を選択する `query_type` を追加。既定の `combined_fields` を維持しつつ、`simple_query_string` の演算子・括弧・フレーズ検索を利用できるよう変更。検索文字列は変換せずそのまま Elasticsearch へ渡す

## [0.5.1] - 2026-07-22

- 検索結果の `params_invalid` を `status` へ置き換え、正常検索、検索body拒否、index不存在を区別できるよう変更
- `SearchResult::STATUS_OK`、`STATUS_PARAMS_INVALID`、`STATUS_INDEX_NOT_FOUND` を追加し、status比較時に定数を使用できるよう変更

## [0.5.0] - 2026-07-22

- `rake_operation_enabled` を追加し、`run_sync_requests` を実行する環境を明示的に限定できるよう変更
- `run_sync_requests` の processing token を固定値にし、rake task が異常中断して token を残した場合も、次回実行で通常同期として再開できるよう変更
- SyncRequest の処理フェーズ、異常中断時の復旧経路、`request_sequence`・`processing_token`・force 処理の役割、古い同期結果を後続のrake通常同期で補正する経路、`retry_count` が増える条件をガイドへ追加
- `request_sequence` の採番処理をproviderへ分離し、PostgreSQL sequenceを使う標準実装を維持しつつ、利用側で継承クラスへ差し替え可能に変更
- More Like This の基準レコードと `mlt_index_target` の対応確認を、モデルクラスの完全一致から Elasticsearch index の一致判定へ変更し、STI 子クラスのレコードを上位モデルの IndexTarget と組み合わせられるよう修正
- 検索結果のActiveRecord復元条件を、`model_includes`・`model_results_where` からモデルごとの `ActiveRecord::Relation` を渡す `model_relations` へ統合。単一targetの `includes`・`results_where` も `relation` へ統合し、Relationの対象クラスは検索対象モデルとの一致を必須化

## [0.4.0] - 2026-07-18

- Elasticsearch index 名を `{index_prefix}__{are_search_ar_table_name}__{index_target_name}` 形式へ変更し、物理 index の timestamp 前も `__` へ統一。index 名の各要素を小文字英字で始まり、小文字英字とアンダーバーだけを使用する形式に限定。※reindexが必要
- `sort` の Array 形式を廃止し、複数条件は記述順を優先順位とする Hash 形式へ統一
- `aggs` をフィールド名をキーとする Hash 形式へ変更し、各フィールドの `size` を必須化。`AreSearch.default_aggs_size` を削除
- index target単位で flock と marker を取得して処理する `are_search_with_index_guard` を追加
- Searchable の継承系統と同一 index 名の所有関係を検査し、STIの検索結果復元を調整
- highlight オプションを整理し、フィールド別設定、`pre_tags`、`post_tags`、`encoder` をそのまま Elasticsearch へ渡すよう変更
- Elasticsearchへ送信するbodyとmappingフィールド名を検査する `SearchBodyPolicy` を追加。標準の `ScriptDenySearchBodyPolicy` はscript系キーを拒否し、利用側でpolicyを差し替え可能
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
