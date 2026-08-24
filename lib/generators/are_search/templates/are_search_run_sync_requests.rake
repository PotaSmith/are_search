# frozen_string_literal: true

# are_search_sync_requests を指定されたstageに限定して回収する。
# 通常同期とforce同期の対象条件は、利用側の運用に合わせて変更できる。
#
# 単一stage。
#   bundle exec rake 'are_search:run_sync_requests[default]'
#
# 複数stage。
#   bundle exec rake 'are_search:run_sync_requests[default,with_external_file]'

namespace :are_search do

    desc "指定されたstageの are_search_sync_requests を再同期する"
    task :run_sync_requests, [:sync_stage_names] => :environment do |_task, args|
        AreSearch.validate_rake_operation_enabled!

        # ロックファイル
        lock_file_path = AreSearch.sync_runner_lock_file_path

        # rake異常中断後に同じ処理として再開するため、固定tokenを使用する。
        # UUIDと衝突しないようにスペースを入れる
        # 既定値は AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN の "rake task"
        processing_token = AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN

        # sync_stage_names は引数で取得する
        sync_stage_names = args.to_a
        if sync_stage_names.empty?
            raise ArgumentError, "sync_stage_names を1件以上指定してください"
        end

        # このタスク内で処理対象にするSearchableモデルの一覧を作成する。
        models = AreSearch::RakeUtils::ArgCheck.load_models
        AreSearch::RakeUtils::ArgCheck.check_sync_stage_names(models, sync_stage_names)

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] run_sync_requests を開始しました。" \
            "sync_stage_names=#{sync_stage_names.inspect}"

        # 通常同期の対象条件。
        normal_threshold = AreSearch.sync_request_delay.seconds.ago
        normal_scope = AreSearch::SyncRequest
            .where(sync_stage_name: sync_stage_names)
            .where("request_sequence_at < ?", normal_threshold)
            .where("sync_try_count < ? OR last_sync_try_at < request_sequence_at", AreSearch.max_sync_try_count,
        )

        # 強制同期の対象条件。
        force_threshold = AreSearch.sync_request_process_hang_wait.seconds.ago
        force_scope = AreSearch::SyncRequest
            .where(sync_stage_name: sync_stage_names)
            .where("processing_at < ?", force_threshold)
            .where("force_try_count < ?", AreSearch.max_force_try_count,
        )

        result = AreSearch::SyncRequestRunner.run(
            models:           models,
            normal_scope:     normal_scope,
            force_scope:      force_scope,
            processing_token: processing_token,
            lock_file_path:   lock_file_path,
        )

        if result.nil?
            puts "[AreSearch] run_sync_requests は別の処理が実行中のためスキップしました " \
                "(#{lock_file_path})"
            next
        end

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] run_sync_requests を終了しました。" \
            "通常同期 #{result[:normal_count]} 件 強制同期 #{result[:force_count]} 件"
    end
end
