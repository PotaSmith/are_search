# frozen_string_literal: true

require "fileutils"

# bundle exec rake are_search:run_sync_requests
# bundle exec rake are_search:mark_all
# bundle exec rake are_search:unmark_all
# bundle exec rake are_search:clean_up_all
# bundle exec rake are_search:check_index_status
# bundle exec rake are_search:check_sync_request_status
# bundle exec rake are_search:reindex_all_for_es_version_up
# bundle exec rake are_search:check_all_models

namespace :are_search do
    desc "AreSearch.sync_request_delay 秒以上未同期の are_search_sync_requests を再同期する"
    task run_sync_requests: :environment do
        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] run_sync_requests を開始しました。"
        done_job_count = 0
        done_force_count = 0

        Rails.application.eager_load!
        # 多重起動を防ぐためロックファイルを flock で排他ロックする。
        # ロックはファイルディスクリプタに紐づき、プロセス終了時にOSが自動解放する。
        # File.open のブロック形にすることで、ブロック離脱時の close で解放が保証され、
        # かつブロック内にいる間ファイルオブジェクトの参照が生きるためGCによる早期解放も防げる。
        lock_path = AreSearch.sync_lock_file_path

        # sync_locks/ が存在しない場合に備えてディレクトリを作成する。
        # これがないと下の File.open が Errno::ENOENT で失敗する。
        FileUtils.mkdir_p(File.dirname(lock_path))

        # 無ければ作る・あれば中身は触らない（RDWR | CREAT、切り詰めなし）
        File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
            # LOCK_NB（ノンブロッキング）で即座に取得可否を返す。
            # 取得できなければ別プロセスが実行中なので、待たずに終了する。
            locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)
            unless locked
                puts "[AreSearch] run_sync_requests は別プロセスが実行中のためスキップしました (#{lock_path})"
                next
            end

            # このタスク内で処理対象にする Searchable モデルの一覧を作成する
            models = ActiveRecord::Base.descendants.select { |klass| klass.include?(AreSearch::Searchable) }

            ar_model_class_names = models.map(&:name)

            threshold = AreSearch.sync_request_delay.seconds.ago
            processing_token = AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN

            # 通常同期。
            # 前回の rake が異常中断して固定 token を残した場合も、同じ token で再開する。
            AreSearch::SyncRequest
                .where(ar_model_class_name: ar_model_class_names)
                .where(processing_token: [nil, processing_token])
                .where("updated_at < ?", threshold)
                .where("retry_count < ?", AreSearch.max_retry_count)
                .find_each do |sync_request|

                # タダの組み合わせなので、index_targetが取れるとは限らない。
                # index_target_name は default のような共通の名前が使われる
                # ただエラーを出すために一応次に投げる
                # そもそも AreSearch::Searchable を include してない可能性もある
                model = sync_request.ar_model_class_name.safe_constantize

                if model != nil && model.respond_to?(:are_search_index_target)
                    index_target = model.are_search_index_target(sync_request.index_target_name)
                else
                    # nilにしてしまって、次でエラーを出させる
                    index_target = nil
                end

                # 対象モデルが reindex 中の場合は are_search_es_sync 側でスキップされる。
                # last_error に "index marked" が記録され、retry_count は増えない。
                AreSearch::RecordSync.sync_with_request(
                    index_target,
                    sync_request,
                    processing_token,
                    on_rake: true,
                )

                done_job_count += 1
            end

            force_threshold = AreSearch.sync_request_process_hang_wait.seconds.ago

            # 強制同期。
            # rake の固定 token は次回の通常同期で再開できるため force 対象にしない。
            AreSearch::SyncRequest
                .where(ar_model_class_name: ar_model_class_names)
                .where.not(processing_token: nil)
                .where.not(processing_token: processing_token)
                .where("processing_at < ?", force_threshold)
                .where("force_attempt_count < ?", AreSearch.max_force_attempt_count)
                .find_each do |sync_request|

                # タダの組み合わせなので、index_targetが取れるとは限らない。
                # index_target_name は default のような共通の名前が使われる
                # ただエラーを出すために一応次に投げる
                # そもそも AreSearch::Searchable を include してない可能性もある
                model = sync_request.ar_model_class_name.safe_constantize

                if model != nil && model.respond_to?(:are_search_index_target)
                    index_target = model.are_search_index_target(sync_request.index_target_name)
                else
                    # nilにしてしまって、次でエラーを出させる
                    index_target = nil
                end

                # processing のまま返ってこない同期を force で回収する。
                # request_sequence は条件に入れない。
                # 詰まり中に同じ行が upsert されると request_sequence は更新されるが、
                # force の対象は「現在この sync request 行が詰まっていること」だから。
                AreSearch::RecordSync.try_force(
                    index_target,
                    sync_request,
                )

                done_force_count += 1
            end
        end
        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] run_sync_requests を終了しました。" \
            "通常 #{done_job_count} 件 強制 #{done_force_count} 件"
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) に manual marker を作成する"
    task mark_all: :environment do
        AreSearch::RakeUtils.searchable_index_names.each do |es_index_name|
            marker = AreSearch.mark_index!(es_index_name)

            if marker
                puts "[AreSearch] mark_all marked: #{es_index_name} marker_id=#{marker.id}"
                next
            end

            existing_marker = AreSearch::IndexMarker.find_by(es_index_name: es_index_name)

            if existing_marker
                puts "[AreSearch] mark_all skipped: #{es_index_name} " \
                    "existing_operation=#{existing_marker.operation} marker_id=#{existing_marker.id}"
            else
                puts "[AreSearch] mark_all skipped: #{es_index_name}"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) の manual marker を削除する"
    task unmark_all: :environment do
        AreSearch::RakeUtils.searchable_index_names.each do |es_index_name|
            deleted_count = AreSearch.unmark_index!(es_index_name)

            if deleted_count > 0
                puts "[AreSearch] unmark_all deleted: #{es_index_name} count=#{deleted_count}"
            else
                puts "[AreSearch] unmark_all skipped: #{es_index_name} manual marker not found"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) から古い物理インデックスを削除する"
    task clean_up_all: :environment do
        AreSearch::RakeUtils.searchable_index_names.each do |es_index_name|
            begin
                result = AreSearch::IndexManager.es_clean_up(es_index_name)

                if result
                    puts "[AreSearch] clean_up done: #{es_index_name}"
                else
                    puts "[AreSearch] clean_up skipped: #{es_index_name} locked"
                end
            rescue AreSearch::IndexOperationViolation
                raise
            rescue StandardError => e
                puts "[AreSearch] clean_up failed: #{es_index_name} #{e.class}: #{e.message}"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) の marker / lock / alias 状態を表示する"
    task check_index_status: :environment do
        es_index_names = AreSearch::RakeUtils.searchable_index_names

        es_index_names.each do |es_index_name|
            lock_path     = AreSearch.index_lock_file_path(es_index_name)
            marker        = AreSearch::IndexMarker.find_by(es_index_name: es_index_name)

            marker_status = marker ? " exists" : "   none"
            marker_detail = "es_index_name=#{es_index_name}"
            unless marker.nil?
                marker_detail = "id=#{marker.id} " \
                    "operation=#{marker.operation} " \
                    "started_at=#{marker.started_at} " \
                    "owner_host=#{marker.owner_host} " \
                    "owner_pid=#{marker.owner_pid}"

                unless marker.message.blank?
                    marker_detail += " message=#{marker.message.inspect}"
                end
            end

            lock_status = "   free"

            FileUtils.mkdir_p(File.dirname(lock_path))

            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)

                if locked
                    lock_file.flock(File::LOCK_UN)
                else
                    lock_status = " locked"
                end
            end

            puts "-------------------------------------------------------------------------"
            puts "[AreSearch] index status: #{es_index_name}"
            puts ""
            puts "       marker: #{marker_status}  #{marker_detail}"
            puts "         lock: #{lock_status  }  #{lock_path}"

            begin
                index_status = AreSearch::IndexManager.es_index_status(es_index_name)
                alias_status = index_status[:alias_exists] ? " exists" : "missing"

                puts "        alias: #{alias_status}  #{index_status[:alias_name]}"
                puts ""
                puts "    current physical:"

                current_physical_names = index_status[:current_physical_names]
                if current_physical_names.empty?
                    puts "                        none"
                else
                    current_physical_names.each do |physical_name|
                        puts "                        #{physical_name}"
                    end
                end

                puts "    physical indexes:"

                physical_indexes = index_status[:physical_indexes]
                if physical_indexes.empty?
                    puts "                        none"
                else
                    physical_indexes.each do |entry|
                        current_label = entry[:current] ? "current" : "unaliased"
                        puts "                        #{entry[:name]} #{current_label}"
                    end
                end

                puts ""
                legacy_index_status = index_status[:legacy_index_exists] ? " exists" : "   none"
                puts " legacy index: #{legacy_index_status}  #{index_status[:alias_name]}"

                warnings = index_status[:warnings].dup
                warnings << "marker exists" unless marker.nil?

                if warnings.empty?
                    puts "      warning:    none"
                else
                    warnings.each do |warning|
                        puts "    warning:    #{warning}"
                    end
                end
            rescue StandardError => e
                puts "    elasticsearch: failed #{e.class}: #{e.message}"
            end
        end
    end


    desc "are_search_sync_requests の marker・件数・エラー内容を表示する"
    task check_sync_request_status: :environment do
        Rails.application.eager_load!

        puts "-------------------------------------------------------------------------"
        puts "[AreSearch] sync request status"
        puts "-------------------------------------------------------------------------"
        puts "マーカー状況"
        puts ""

        marker_rows = AreSearch::RakeUtils.index_marker_status_rows
        if marker_rows.empty?
            puts "なし"
        else
            marker_headers = [
                "ESインデックス名",
                "操作",
                "開始日時",
                "ホスト",
                "PID",
                "メッセージ",
            ]

            AreSearch::RakeUtils.fixed_width_table_lines(marker_headers, marker_rows).each do |line|
                puts line
            end
        end

        puts ""
        puts "-------------------------------------------------------------------------"
        puts "リクエスト数"
        puts ""

        request_rows = AreSearch::RakeUtils.sync_request_status_rows
        if request_rows.empty?
            puts "なし"
        else
            request_headers = [
                "テーブル名",
                "モデル",
                "データ数",
                "エラー数",
            ]

            AreSearch::RakeUtils.fixed_width_table_lines(request_headers, request_rows).each do |line|
                puts line
            end
        end

        puts ""
        puts "-------------------------------------------------------------------------"
        puts "エラー内容 トップ20"
        puts ""

        error_rows = AreSearch::RakeUtils.sync_request_error_status_rows(20)
        if error_rows.empty?
            puts "なし"
        else
            error_headers = [
                "テーブル名",
                "内容",
                "件数",
            ]

            AreSearch::RakeUtils.fixed_width_table_lines(error_headers, error_rows).each do |line|
                puts line
            end
        end
        puts ""
    end


    desc "Elasticsearch のバージョンアップ前に全 Searchable index(STI重複なし) を reindex する"
    task reindex_all_for_es_version_up: :environment do
        sync_request_count = AreSearch::SyncRequest.count

        if sync_request_count > 0
            raise AreSearch::Error,
                "[AreSearch] are_search_sync_requests に #{sync_request_count} 件残っているため reindex できません"
        end

        index_targets = AreSearch::RakeUtils.searchable_index_target_for_reindex
        searchable_index_names = index_targets.map(&:are_search_es_index_name)
        actual_index_names = []

        begin
            response = AreSearch.client.indices.get(
                index: "#{AreSearch.index_prefix}#{AreSearch::ES_INDEX_NAME_DELIMITER}*",
            )
            actual_index_names = response.keys
        rescue Elastic::Transport::Transport::Errors::NotFound
            actual_index_names = []
        end

        current_physical_index_names = []
        searchable_index_names.each do |es_index_name|
            physical_index_names = AreSearch::IndexManager.es_get_alias_physical_names(es_index_name)
            current_physical_index_names.concat(physical_index_names)
        end

        orphaned_index_names = actual_index_names - current_physical_index_names
        orphaned_index_names.sort!

        if orphaned_index_names.any?
            message = "[AreSearch] 管理対象外または未接続の index が残っているため reindex できません:\n"
            orphaned_index_names.each do |index_name|
                message += "  #{index_name}\n"
            end

            raise AreSearch::Error, message.rstrip
        end

        puts "以下の index を reindex します。"
        puts ""
        searchable_index_names.each do |es_index_name|
            puts "  #{es_index_name}"
        end
        puts ""
        print "実行しますか？ [y/N]: "

        answer = $stdin.gets
        if answer.nil?
            answer = ""
        end

        unless answer.strip.downcase == "y"
            puts "[AreSearch] reindex canceled."
            next
        end

        index_targets.each do |index_target|
            es_index_name = index_target.are_search_es_index_name
            result = index_target.are_search_es_reindex

            if result == false
                raise AreSearch::Error, "[AreSearch] reindex が実行できませんでした: #{es_index_name}"
            end

            if result.any?
                raise AreSearch::Error, "[AreSearch] reindex に失敗した ID があります: #{es_index_name} #{result.inspect}"
            end

            puts "[AreSearch] reindex done: #{es_index_name}"
        end
    end


    desc "AreSearch::Searchable を include している全モデルのコールバック順序・実装漏れをチェックする"
    task check_all_models: :environment do
        Rails.application.eager_load!
        errors = []

        AreSearch::RakeUtils.check_callback_order(errors)

        ActiveRecord::Base.descendants.select { |klass| klass.include?(AreSearch::Searchable) }.each do |klass|
            save_callbacks = klass._save_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts klass.name
            puts "after_save    : #{save_callbacks.inspect}"

            if save_callbacks.count(:are_search_enqueue_es_sync_request) == 0
                errors << "#{klass.name}: after_save :are_search_enqueue_es_sync_request がありません"
            end

            if save_callbacks.count(:are_search_enqueue_es_sync_request) > 1
                errors << "#{klass.name}: after_save :are_search_enqueue_es_sync_request が重複しています。"
            end

            destroy_callbacks = klass._destroy_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts "after_destroy : #{destroy_callbacks.inspect}"

            if destroy_callbacks.count(:are_search_enqueue_es_sync_request) == 0
                errors << "#{klass.name}: after_destroy :are_search_enqueue_es_sync_request がありません。"
            end

            if destroy_callbacks.count(:are_search_enqueue_es_sync_request) > 1
                errors << "#{klass.name}: after_destroy :are_search_enqueue_es_sync_request が重複しています。"
            end

            touch_callbacks = klass._touch_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts "after_touch   : #{touch_callbacks.inspect}"

            if touch_callbacks.count(:are_search_enqueue_es_sync_request) == 0
                errors << "#{klass.name}: after_touch :are_search_enqueue_es_sync_request がありません。"
            end

            if touch_callbacks.count(:are_search_enqueue_es_sync_request) > 1
                errors << "#{klass.name}: after_touch :are_search_enqueue_es_sync_request が重複しています。"
            end

            commit_callbacks = klass._commit_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts "after_commit  : #{commit_callbacks.inspect}"

            if commit_callbacks.count(:are_search_after_commit) == 0
                errors << "#{klass.name}: after_commit :are_search_after_commit がありません。"
            end

            if commit_callbacks.count(:are_search_after_commit) > 1
                errors << "#{klass.name}: after_commit :are_search_after_commit が重複しています。"
            end

            AreSearch::RakeUtils.model_check(klass, errors)
        end

        AreSearch::RakeUtils.validate_searchable_index_name_ownership(errors)

        errors.empty? ? puts("全モデル正常") : puts(errors.join("\n"))
    end
end
