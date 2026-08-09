# frozen_string_literal: true

require "rails_helper"
require "active_job"
require "rake"
require_relative "../support/integration_support"

RSpec.describe "AreSearch sync integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_queue_adapter = ActiveJob::Base.queue_adapter
        original_rake_application = Rake.application

        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        ActiveJob::Base.queue_adapter = original_queue_adapter
        Rake.application = original_rake_application
    end

    # run_sync_requests の配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    it "after_commit_mode noneで残ったSyncRequestをrakeで同期する" do
        AreSearch.after_commit_mode = :none
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "rakesynctoken",
            body:    "rake sync body",
            status:  "published",
            user_id: 201,
        )

        sync_request = AreSearch::SyncRequest.find_by!(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document.id.to_s,
            sync_stage_name:     "default",
        )
        expect(sync_request.processing_token).to eq(nil)

        refresh_document_first_index
        before_result = search_document_first("rakesynctoken")
        expect(before_result.records).to eq([])

        load_run_sync_requests_task
        Rake::Task["are_search:run_sync_requests"].invoke("default")

        expect(
            AreSearch::SyncRequest.find_by(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(nil)

        refresh_document_first_index
        after_result = search_document_first("rakesynctoken")

        expect(after_result.records.map(&:id)).to eq([document.id])
    end

    it "after_commit_mode jobでenqueueしたSyncJobを実行すると同期する" do
        AreSearch.after_commit_mode = :job
        ActiveJob::Base.queue_adapter = :test
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "jobsynctoken",
            body:    "job sync body",
            status:  "published",
            user_id: 202,
        )

        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(true)

        queued_job = ActiveJob::Base.queue_adapter.enqueued_jobs.find do |job|
            job[:job] == AreSearch::SyncJob
        end

        expect(queued_job).not_to eq(nil)

        AreSearch::SyncJob.perform_now(*queued_job[:args])

        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(false)

        refresh_document_first_index
        result = search_document_first("jobsynctoken")

        expect(result.records.map(&:id)).to eq([document.id])
    end

    it "destroyするとdirect同期でElasticsearchから削除する" do
        AreSearch.after_commit_mode = :direct

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "deletesynctoken",
            body:    "delete sync body",
            status:  "published",
            user_id: 203,
        )

        refresh_document_first_index
        before_result = search_document_first("deletesynctoken")
        expect(before_result.records.map(&:id)).to eq([document.id])

        document.destroy!

        refresh_document_first_index
        after_result = search_document_first("deletesynctoken")

        expect(after_result.records).to eq([])
        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(false)
    end
end
