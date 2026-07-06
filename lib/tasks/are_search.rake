# frozen_string_literal: true

require "fileutils"

# bundle exec rake are_search:check_all_models
# bundle exec rake are_search:run_sync_requests
# bundle exec rake are_search:clean_up_all
# bundle exec rake are_search:check_index_status
# bundle exec rake are_search:mark_all
# bundle exec rake are_search:unmark_all

namespace :are_search do
    desc "AreSearch::Searchable を include している全モデルのコールバック順序・実装漏れをチェックする"
    task check_all_models: :environment do
        AreSearch.check_all_models!
    end


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
            models = []
            ActiveRecord::Base.descendants.each do |klass|
                next unless klass.include?(AreSearch::Searchable)

                models << klass
            end

            ar_model_class_names = models.map(&:name)

            threshold = AreSearch.sync_request_delay.seconds.ago
            processing_token = SecureRandom.uuid

            # 通常同期
            AreSearch::SyncRequest
                .where(ar_model_class_name: ar_model_class_names)
                .where(processing_token: nil)
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

            # 強制同期
            AreSearch::SyncRequest
                .where(ar_model_class_name: ar_model_class_names)
                .where.not(processing_token: nil)
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


    desc "AreSearch::Searchable を include している全モデルの古い物理インデックスを削除する"
    task clean_up_all: :environment do
        AreSearch.searchable_index_names.each do |es_index_name|
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


    desc "AreSearch::Searchable を include している全モデルの index marker / lock / alias 状態を表示する"
    task check_index_status: :environment do
        es_index_names = AreSearch.searchable_index_names

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


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) に manual marker を作成する"
    task mark_all: :environment do
        results = AreSearch.mark_all!

        results.each do |result|
            marker = result[:marker]

            if result[:marked]
                puts "[AreSearch] mark_all marked: #{result[:es_index_name]} marker_id=#{marker.id}"
            elsif marker
                puts "[AreSearch] mark_all skipped: #{result[:es_index_name]} existing_operation=#{marker.operation} marker_id=#{marker.id}"
            else
                puts "[AreSearch] mark_all skipped: #{result[:es_index_name]}"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) の manual marker を削除する"
    task unmark_all: :environment do
        results = AreSearch.unmark_all!

        results.each do |result|
            if result[:deleted_count] > 0
                puts "[AreSearch] unmark_all deleted: #{result[:es_index_name]} count=#{result[:deleted_count]}"
            else
                puts "[AreSearch] unmark_all skipped: #{result[:es_index_name]} manual marker not found"
            end
        end
    end
end
