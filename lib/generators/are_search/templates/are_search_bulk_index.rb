# frozen_string_literal: true

# 変更箇所: 対象モデルと IndexTarget を指定する。
index_target = Article.are_search_index_target(:new_version)

# 変更箇所: BulkIndexer で使用する stage を指定する。
sync_stage_name = "for_version_up"

# 処理結果を保存するディレクトリのパス
result_dir = 'result_dir_path'

# 変更箇所: 1回のbulk送信上限を指定する。
max_bulk_bytes = 20 * 1024 * 1024
max_bulk_count = 100
max_fail_count = 100

bulk_mode = ARGV.fetch(0, "index")

unless ["index", "recover"].include?(bulk_mode)
    raise ArgumentError,
        "index または recover を指定してください"
end

index_target.are_search_bulk_index(
    sync_stage_name,
    result_dir: result_dir,
    max_bulk_bytes: max_bulk_bytes,
    max_bulk_count: max_bulk_count,
    max_fail_count: max_fail_count,
    recover: bulk_mode == "recover",
)
