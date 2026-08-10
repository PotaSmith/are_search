# frozen_string_literal: true

require "rails_helper"
require "rake"
require_relative "../support/integration_support"

RSpec.describe "AreSearch sync state integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_rake_application = Rake.application

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        clear_are_search_integration_records
        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        Rake.application = original_rake_application
    end

    # run_sync_requests の配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    # default stage のSyncRequestをrakeから1回回収する。
    def run_default_sync_requests
        task = Rake::Task["are_search:run_sync_requests"]
        task.reenable
        task.invoke("default")
    end

    # 指定レコードのdefault stageのSyncRequestを返す。
    def default_sync_request_for(document_id)
        AreSearch::SyncRequest.find_by(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document_id.to_s,
            sync_stage_name:     "default",
        )
    end

    it "同期中に同じレコードが更新されても新しいrequest_sequenceを残して次回同期で最新内容へ追従する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "sequencestate first",
            body:    "sequence state body",
            status:  "published",
            user_id: 1701,
        )
        document.update!(title: "sequencestate second")

        request_before_sync = default_sync_request_for(document.id)
        expect(request_before_sync).not_to eq(nil)

        update_during_sync = true
        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_or_delete!)
            .and_wrap_original do |original_method, *args|
                result = original_method.call(*args)

                if update_during_sync
                    update_during_sync = false
                    document.update!(title: "sequencestate latest")
                end

                result
            end

        load_run_sync_requests_task
        run_default_sync_requests

        request_after_first_sync = default_sync_request_for(document.id)
        expect(request_after_first_sync).not_to eq(nil)
        expect(request_after_first_sync.request_sequence).to be > request_before_sync.request_sequence

        refresh_document_first_index
        first_sync_result = search_document_first("sequencestate second")
        latest_before_retry = search_document_first("sequencestate latest")
        expect(first_sync_result.records.map(&:id)).to eq([document.id])
        expect(latest_before_retry.records).to eq([])

        run_default_sync_requests

        expect(default_sync_request_for(document.id)).to eq(nil)

        refresh_document_first_index
        stale_result = search_document_first("sequencestate second")
        latest_result = search_document_first("sequencestate latest")
        expect(stale_result.records).to eq([])
        expect(latest_result.records.map(&:id)).to eq([document.id])
    end

    it "未処理の更新要求があるレコードを削除するとrake回収後はElasticsearchから削除される" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        AreSearch.after_commit_mode = :direct
        document = DocumentFirst.create!(
            title:   "updatedeletestate original",
            body:    "update delete body",
            status:  "published",
            user_id: 1702,
        )
        AreSearch.after_commit_mode = :none

        document.update!(title: "updatedeletestate pending")
        document_id = document.id
        document.destroy!

        expect(default_sync_request_for(document_id)).not_to eq(nil)

        load_run_sync_requests_task
        run_default_sync_requests

        expect(default_sync_request_for(document_id)).to eq(nil)

        refresh_document_first_index
        original_result = search_document_first("updatedeletestate original")
        pending_result = search_document_first("updatedeletestate pending")
        expect(original_result.records).to eq([])
        expect(pending_result.records).to eq([])
    end

    it "削除要求が未処理の同じIDを再作成すると古い削除要求ではなく現在のレコードを同期する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        AreSearch.after_commit_mode = :direct
        document = DocumentFirst.create!(
            title:   "recreatestate old",
            body:    "recreate old body",
            status:  "published",
            user_id: 1703,
        )
        AreSearch.after_commit_mode = :none

        document_id = document.id
        document.destroy!
        delete_request = default_sync_request_for(document_id)
        expect(delete_request).not_to eq(nil)

        recreated = DocumentFirst.create!(
            id:      document_id,
            title:   "recreatestate new",
            body:    "recreate new body",
            status:  "published",
            user_id: 1704,
        )
        recreate_request = default_sync_request_for(document_id)
        expect(recreate_request.request_sequence).to be > delete_request.request_sequence

        load_run_sync_requests_task
        run_default_sync_requests

        expect(default_sync_request_for(document_id)).to eq(nil)

        refresh_document_first_index
        old_result = search_document_first("recreatestate old")
        new_result = search_document_first("recreatestate new")
        expect(old_result.records).to eq([])
        expect(new_result.records.map(&:id)).to eq([recreated.id])
    end

    it "未処理SyncRequestを保持したままreindexしてもalias切替後のrake回収で最新状態を維持する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        AreSearch.after_commit_mode = :direct
        document = DocumentFirst.create!(
            title:   "reindexpendingstate original",
            body:    "reindex pending body",
            status:  "published",
            user_id: 1705,
        )
        AreSearch.after_commit_mode = :none

        document.update!(title: "reindexpendingstate latest")
        request_before_reindex = default_sync_request_for(document.id)
        expect(request_before_reindex).not_to eq(nil)

        second_reindex_result = document_first_index_target.are_search_reindex(
            stage_position: :first,
        )
        expect(second_reindex_result[:result]).to eq(:success)
        expect(default_sync_request_for(document.id)).not_to eq(nil)

        load_run_sync_requests_task
        run_default_sync_requests

        expect(default_sync_request_for(document.id)).to eq(nil)

        refresh_document_first_index
        old_result = search_document_first("reindexpendingstate original")
        latest_result = search_document_first("reindexpendingstate latest")
        expect(old_result.records).to eq([])
        expect(latest_result.records.map(&:id)).to eq([document.id])
    end
end
