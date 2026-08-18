# frozen_string_literal: true

require "fileutils"

# bundle exec rake are_search:acquire_sync_lock_all
# bundle exec rake are_search:release_sync_lock_all
# bundle exec rake are_search:clean_up_all
# bundle exec rake are_search:check_index_status
# bundle exec rake are_search:check_sync_request_status
# bundle exec rake are_search:reindex_all_for_es_version_up
# bundle exec rake are_search:check_all_models

namespace :are_search do

    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) に manual sync lock を取得する"
    task acquire_sync_lock_all: :environment do
        AreSearch::RakeUtils.searchable_index_targets.each do |index_target|
            index_alias_name = index_target.are_search_index_alias_name
            sync_lock = index_target.are_search_acquire_sync_lock!

            if sync_lock
                puts "[AreSearch] acquire_sync_lock_all acquired: #{index_alias_name} sync_lock_id=#{sync_lock.id}"
                next
            end

            existing_sync_lock = AreSearch::SyncLock.find_by(
                index_alias_name: index_alias_name,
                sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            )

            if existing_sync_lock
                puts "[AreSearch] acquire_sync_lock_all skipped: #{index_alias_name} " \
                    "existing_operation=#{existing_sync_lock.operation} sync_lock_id=#{existing_sync_lock.id}"
            else
                puts "[AreSearch] acquire_sync_lock_all skipped: #{index_alias_name}"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) の manual sync lock を解放する"
    task release_sync_lock_all: :environment do
        AreSearch::RakeUtils.searchable_index_targets.each do |index_target|
            index_alias_name = index_target.are_search_index_alias_name
            deleted_count = index_target.are_search_release_sync_lock!

            if deleted_count > 0
                puts "[AreSearch] release_sync_lock_all released: #{index_alias_name} count=#{deleted_count}"
            else
                puts "[AreSearch] release_sync_lock_all skipped: #{index_alias_name} manual sync lock not found"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) から古い物理インデックスを削除する"
    task clean_up_all: :environment do
        AreSearch::RakeUtils.searchable_index_targets.each do |index_target|
            index_alias_name = index_target.are_search_index_alias_name

            begin
                result = index_target.are_search_clean_up

                if result[:result] == :success
                    puts "[AreSearch] clean_up done: #{index_alias_name}"
                else
                    puts "[AreSearch] clean_up failed: stopped at #{result[:stop_phase]}"
                end
            rescue AreSearch::IndexOperationViolation
                raise
            rescue StandardError => e
                puts "[AreSearch] clean_up failed: #{index_alias_name} #{e.class}: #{e.message}"
            end
        end
    end


    desc "AreSearch::Searchable を include している全モデルの index(STI重複なし) の sync lock / index lock / alias 状態を表示する"
    task check_index_status: :environment do
        index_targets = AreSearch::RakeUtils.searchable_index_targets

        index_targets.each do |index_target|
            index_alias_name = index_target.are_search_index_alias_name
            lock_path = AreSearch.index_lock_file_path(index_alias_name)
            sync_locks = AreSearch::SyncLock.where(index_alias_name: index_alias_name).order(:id)
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
            puts "[AreSearch] index status: #{index_alias_name}"
            puts ""
            if sync_locks.empty?
                puts "    sync lock:    none  index_alias_name=#{index_alias_name}"
            else
                sync_locks.each do |sync_lock|
                    sync_lock_detail = "id=#{sync_lock.id} sync_stage_name=#{sync_lock.sync_stage_name.inspect} " \
                        "operation=#{sync_lock.operation} started_at=#{sync_lock.started_at} " \
                        "owner_host=#{sync_lock.owner_host} owner_pid=#{sync_lock.owner_pid}"
                    sync_lock_detail += " message=#{sync_lock.message.inspect}" unless sync_lock.message.blank?

                    puts "    sync lock:  exists  #{sync_lock_detail}"
                end
            end

            puts "         lock: #{lock_status}  #{lock_path}"

            begin
                alias_response = AreSearch::EsAdapter.indices_get_alias(index_alias_name: index_alias_name)
                current_physical_names = alias_response.keys

                physical_response = AreSearch::EsAdapter.physical_indices_for_alias(index_alias_name: index_alias_name)
                physical_names = physical_response.keys.select do |physical_name|
                    source_alias_name = AreSearch::IndexDefinition.index_alias_name_from_physical_index_name(physical_name)
                    source_alias_name == index_alias_name
                end.sort

                alias_named_physical_index = AreSearch::EsAdapter.alias_named_physical_index(
                    index_alias_name: index_alias_name,
                )
                alias_named_physical_index_exists = alias_named_physical_index.key?(index_alias_name)

                puts "        alias: #{alias_response.empty? ? 'missing' : ' exists'}  #{index_alias_name}"
                puts ""
                puts "    current physical:"

                if current_physical_names.empty?
                    puts "                        none"
                else
                    current_physical_names.each do |physical_name|
                        puts "                        #{physical_name}"
                    end
                end

                physical_creation_dates = {}
                physical_names.each do |physical_name|
                    creation_date = physical_response.dig(
                        physical_name,
                        "settings",
                        "index",
                        "creation_date",
                    )
                    next if creation_date.nil?

                    physical_creation_dates[physical_name] = creation_date.to_i
                end

                puts "    physical indexes:"

                if physical_names.empty?
                    puts "                        none"
                else
                    physical_names.each do |physical_name|
                        current_label = current_physical_names.include?(physical_name) ? "current  " : "unaliased"
                        creation_date = physical_creation_dates[physical_name]
                        creation_date_text = if creation_date.nil?
                            "unknown"
                        else
                            Time.at(creation_date / 1000.0).utc.iso8601(6)
                        end

                        puts "                        #{current_label} - #{physical_name} : creation_date #{creation_date_text}"
                    end
                end

                puts ""
                alias_named_status = alias_named_physical_index_exists ? " exists" : "   none"
                puts " alias named physical index:"
                puts "               #{alias_named_status}  #{index_alias_name}"

                warnings = []
                warnings << "alias missing" if current_physical_names.empty?

                if current_physical_names.empty? && physical_names.empty? && alias_named_physical_index_exists == false
                    warnings << "physical index missing"
                end

                invalid_current_exists = current_physical_names.any? do |physical_name|
                    source_alias_name = AreSearch::IndexDefinition.index_alias_name_from_physical_index_name(physical_name)
                    source_alias_name != index_alias_name
                end
                warnings << "current physical index is not AreSearch format" if invalid_current_exists

                if alias_named_physical_index_exists
                    warnings << "physical index with alias name exists"
                end

                newest_physical_name = physical_creation_dates.max_by do |_physical_name, creation_date|
                    creation_date
                end&.first

                if newest_physical_name && current_physical_names.any?
                    unless current_physical_names.include?(newest_physical_name)
                        warnings << "newest physical index is not current"
                    end
                end

                warnings << "sync lock exists" if sync_locks.any?

                if warnings.empty?
                    puts "      warning:    none"
                else
                    warnings.each do |warning|
                        puts "      warning:    #{warning}"
                    end
                end
            rescue StandardError => e
                puts "    elasticsearch: failed #{e.class}: #{e.message}"
            end
        end
    end


    desc "are_search_sync_requests の sync lock・同期経路別件数・エラー内容を表示する"
    task check_sync_request_status: :environment do
        Rails.application.eager_load!

        puts "-------------------------------------------------------------------------"
        puts "[AreSearch] sync request status"
        puts "-------------------------------------------------------------------------"
        puts "同期ロック状況"
        puts ""

        sync_lock_rows = AreSearch::RakeUtils::CheckSyncRequestStatus.sync_lock_status_rows
        if sync_lock_rows.empty?
            puts "なし"
        else
            sync_lock_headers = [
                "ESインデックス名",
                "同期stage",
                "操作",
                "開始日時",
                "ホスト",
                "PID",
                "メッセージ",
            ]

            AreSearch::RakeUtils::CheckSyncRequestStatus.fixed_width_table_lines(sync_lock_headers, sync_lock_rows).each do |line|
                puts line
            end
        end

        puts ""
        puts "-------------------------------------------------------------------------"
        puts "リクエスト数"
        puts ""

        request_rows = AreSearch::RakeUtils::CheckSyncRequestStatus.sync_request_status_rows
        if request_rows.empty?
            puts "なし"
        else
            request_headers = [
                "モデル",
                "IndexTarget",
                "同期stage",
                "リクエスト数",
                "処理中",
                "エラー",
            ]

            AreSearch::RakeUtils::CheckSyncRequestStatus.fixed_width_table_lines(request_headers, request_rows).each do |line|
                puts line
            end
        end

        puts ""
        puts "-------------------------------------------------------------------------"
        puts "エラー内容 トップ20"
        puts ""

        error_rows = AreSearch::RakeUtils::CheckSyncRequestStatus.sync_request_error_status_rows(20)
        if error_rows.empty?
            puts "なし"
        else
            error_headers = [
                "モデル",
                "IndexTarget",
                "同期stage",
                "内容",
                "件数",
            ]

            AreSearch::RakeUtils::CheckSyncRequestStatus.fixed_width_table_lines(error_headers, error_rows).each do |line|
                puts line
            end
        end
        puts ""
    end


    desc "Elasticsearch のバージョンアップ前に全 Searchable index(STI重複なし) を最終stageでreindexする"
    task reindex_all_for_es_version_up: :environment do
        reindex_utils = AreSearch::RakeUtils::ReindexAllForEsVersionUp

        reindex_utils.validate_no_sync_requests!

        index_targets = reindex_utils.searchable_index_targets_for_reindex
        reindex_utils.validate_no_unconnected_indexes!(index_targets)

        puts "以下の index を reindex します。"
        puts ""
        index_targets.each do |index_target|
            puts "  #{index_target.are_search_index_alias_name}"
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

        # index target を順番に最終stageでreindexする。
        index_targets.each do |index_target|
            result = index_target.are_search_reindex(
                stage_position: :last,
            )

            if result[:failed_ids].any?
                raise AreSearch::Error,
                    "[AreSearch] reindex に失敗したデータがあります: " \
                    "#{index_target.are_search_index_alias_name} #{result.inspect}"
            end

            if result[:result] != :success
                raise AreSearch::Error,
                    "[AreSearch] reindex を実行できませんでした: " \
                    "#{index_target.are_search_index_alias_name} " \
                    "stopped at #{result[:stop_phase]}"
            end

            puts "[AreSearch] reindex が完了しました: #{index_target.are_search_index_alias_name}"
        end
    end


    desc "AreSearch::Searchable を include している全モデルのコールバック順序・実装漏れをチェックする"
    task check_all_models: :environment do
        Rails.application.eager_load!
        errors = []

        AreSearch::RakeUtils::CheckAllModels.check_callback_order(errors)

        ActiveRecord::Base.descendants.select { |klass| klass.include?(AreSearch::Searchable) }.each do |klass|
            save_callbacks = klass._save_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts klass.name
            puts "after_save    : #{save_callbacks.inspect}"

            if save_callbacks.count(:are_search_enqueue_sync_request) == 0
                errors << "#{klass.name}: after_save :are_search_enqueue_sync_request がありません"
            end

            if save_callbacks.count(:are_search_enqueue_sync_request) > 1
                errors << "#{klass.name}: after_save :are_search_enqueue_sync_request が重複しています。"
            end

            destroy_callbacks = klass._destroy_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts "after_destroy : #{destroy_callbacks.inspect}"

            if destroy_callbacks.count(:are_search_enqueue_sync_request) == 0
                errors << "#{klass.name}: after_destroy :are_search_enqueue_sync_request がありません。"
            end

            if destroy_callbacks.count(:are_search_enqueue_sync_request) > 1
                errors << "#{klass.name}: after_destroy :are_search_enqueue_sync_request が重複しています。"
            end

            touch_callbacks = klass._touch_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts "after_touch   : #{touch_callbacks.inspect}"

            if touch_callbacks.count(:are_search_enqueue_sync_request) == 0
                errors << "#{klass.name}: after_touch :are_search_enqueue_sync_request がありません。"
            end

            if touch_callbacks.count(:are_search_enqueue_sync_request) > 1
                errors << "#{klass.name}: after_touch :are_search_enqueue_sync_request が重複しています。"
            end

            commit_callbacks = klass._commit_callbacks.select { |cb| cb.kind == :after }.map(&:filter)

            puts "after_commit  : #{commit_callbacks.inspect}"

            if commit_callbacks.count(:are_search_after_commit) == 0
                errors << "#{klass.name}: after_commit :are_search_after_commit がありません。"
            end

            if commit_callbacks.count(:are_search_after_commit) > 1
                errors << "#{klass.name}: after_commit :are_search_after_commit が重複しています。"
            end

            AreSearch::RakeUtils::CheckAllModels.model_check(klass, errors)
        end

        if errors.empty?
            AreSearch::RakeUtils::CheckAllModels.validate_searchable_index_alias_name_ownership(errors)
        end

        errors.empty? ? puts("全モデル正常") : puts(errors.join("\n"))
    end
end
