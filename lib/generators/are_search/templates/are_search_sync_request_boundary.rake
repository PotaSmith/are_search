# frozen_string_literal: true

module AreSearchSyncRequestBoundaryTask

    # 変更箇所: 対象のモデル・IndexTarget・stageを指定する。
    INDEX_TARGET_MODEL_CLASS_NAME = "SampleData"
    INDEX_TARGET_NAME = "name"
    SYNC_STAGE_NAME = "sample"

    extend self

    # 設定されたIndexTargetを返す。
    def index_target
        INDEX_TARGET_MODEL_CLASS_NAME.constantize.are_search_index_target(INDEX_TARGET_NAME)
    end

    # 対象IndexTarget・stageのSyncRequestをすべて削除する。
    def delete_sync_stage_all_sync_requests!
        AreSearch.validate_rake_operation_enabled!

        deleted_count = sync_request_scope.delete_all

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] sync_requestを削除しました。#{deleted_count}件"
    end

    # 現在のBoundaryTargetを表示する。
    def show_boundary_target!
        AreSearch.validate_rake_operation_enabled!

        boundary_target =  index_target.are_search_find_sync_request_boundary_target!(SYNC_STAGE_NAME)
        if boundary_target.nil?
            puts "SyncRequestBoundaryTargetがありません"
            return
        end

        puts "BoundaryTarget limit=#{boundary_target.sequence_limit} created_at=#{boundary_target.created_at}"
    end

    # request_sequenceを新しく採番し、BoundaryTargetの境界として保存する。
    # 既にBoundaryTargetが存在する場合は例外になる。
    def set_boundary_target!
        AreSearch.validate_rake_operation_enabled!

        boundary_target = index_target.are_search_set_sync_request_boundary_target!(SYNC_STAGE_NAME)

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] BoundaryTargetをセットしました。" \
            "limit=#{boundary_target.sequence_limit}"
    end

    # 既存のBoundaryTargetを削除する。
    def clear_boundary_target!
        AreSearch.validate_rake_operation_enabled!

        index_target.are_search_clear_sync_request_boundary_target!(SYNC_STAGE_NAME)

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] BoundaryTargetをクリアしました。"
    end

    # request_sequenceがBoundaryTargetのsequence_limit以下のSyncRequestだけを同期する。
    def run_sync_requests!
        AreSearch.validate_rake_operation_enabled!

        boundary_target =  index_target.are_search_find_sync_request_boundary_target!(SYNC_STAGE_NAME)
        if boundary_target.nil?
            puts "SyncRequestBoundaryTargetがありません"
            return
        end

        target_scope = boundary_maybe_before_sync_request_scope(boundary_target)
        before_count = target_scope.count

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] Boundary同期対象 実行前 #{before_count}件"
        return if before_count == 0

        print "同期を実行しますか？ [y/N]: "

        answer = $stdin.gets
        if answer.nil?
            answer = ""
        end

        unless answer.strip.downcase == "y"
            puts "[AreSearch] Boundary同期をキャンセルしました。"
            return
        end

        Rails.application.eager_load!

        models = ActiveRecord::Base.descendants.select do |model|
            model.include?(AreSearch::Searchable)
        end

        boundary_target.update_columns(last_sync_started_at: Time.zone.now)

        lock_file_path = AreSearch.sync_runner_lock_file_path
        result = AreSearch::SyncRequestRunner.run(
            models:           models,
            normal_scope:     target_scope,
            force_scope:      AreSearch::SyncRequest.none,
            processing_token: AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN,
            lock_file_path:   lock_file_path,
        )

        boundary_target.update_columns(last_sync_ended_at: Time.zone.now)

        if result.nil?
            puts "[AreSearch] Boundary同期は別のsync request処理が実行中のためスキップしました (#{lock_file_path})"
            return
        end

        after_count = boundary_maybe_before_sync_request_scope(boundary_target).count
        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] Boundary同期対象 実行後 #{after_count}件"
    end

    # request_sequenceがBoundaryTargetのsequence_limitより後のSyncRequestを削除する。
    def delete_sync_requests_after_boundary_target!
        AreSearch.validate_rake_operation_enabled!

        boundary_target =  index_target.are_search_find_sync_request_boundary_target!(SYNC_STAGE_NAME)
        if boundary_target.nil?
            puts "SyncRequestBoundaryTargetがありません"
            return
        end

        deleted_count = boundary_after_sync_request_scope(boundary_target).delete_all

        puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] sync_requestを削除しました。#{deleted_count}件"
    end

    private

    # 設定されたIndexTarget・stageのSyncRequestだけに限定する。
    def sync_request_scope
        AreSearch::SyncRequest.where(
            index_alias_name: index_target.are_search_index_alias_name,
            sync_stage_name:  SYNC_STAGE_NAME,
        )
    end

    # request_sequenceが境界以下のSyncRequestを返す。
    # commitの前後関係は判定せず、同期対象を安全側に広く取る。
    #
    # 同期用
    def boundary_maybe_before_sync_request_scope(boundary_target)
        sync_request_scope.where("request_sequence <= ?", boundary_target.sequence_limit)
    end

    # request_sequenceが境界より後のSyncRequestを返す。
    # commitの前後関係は判定せず、境界以下のSyncRequestは削除対象から除外する。
    #
    # 削除や除外用
    def boundary_after_sync_request_scope(boundary_target)
        sync_request_scope.where.not("request_sequence <= ?", boundary_target.sequence_limit)
    end
end

namespace :are_search do

    desc "BoundaryTargetのIndexTarget-stageのSyncRequestを削除する"
    task delete_sync_stage_all_sync_requests: :environment do
        AreSearchSyncRequestBoundaryTask.delete_sync_stage_all_sync_requests!
    end

    desc "BoundaryTargetをセットする"
    task set_sync_request_boundary: :environment do
        AreSearchSyncRequestBoundaryTask.set_boundary_target!
    end

    desc "BoundaryTargetを確認する"
    task show_sync_request_boundary: :environment do
        AreSearchSyncRequestBoundaryTask.show_boundary_target!
    end

    desc "BoundaryTargetを削除する"
    task clear_sync_request_boundary: :environment do
        AreSearchSyncRequestBoundaryTask.clear_boundary_target!
    end

    desc "BoundaryTarget以前のSyncRequestを同期する"
    task run_sync_request_before_boundary: :environment do
        AreSearchSyncRequestBoundaryTask.run_sync_requests!
    end

    desc "BoundaryTarget以降のIndexTarget-stageのSyncRequestを削除する"
    task delete_sync_requests_after_boundary_target: :environment do
        AreSearchSyncRequestBoundaryTask.delete_sync_requests_after_boundary_target!
    end
end
