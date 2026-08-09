# frozen_string_literal: true

require "rails_helper"
require "rake"
require_relative "../support/integration_support"

RSpec.describe "AreSearch force sync integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_sync_request_process_hang_wait = AreSearch.sync_request_process_hang_wait
        original_max_force_try_count = AreSearch.max_force_try_count
        original_rake_application = Rake.application

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0
        AreSearch.sync_request_process_hang_wait = 0
        AreSearch.max_force_try_count = 5

        clear_are_search_integration_records

        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        AreSearch.sync_request_process_hang_wait = original_sync_request_process_hang_wait
        AreSearch.max_force_try_count = original_max_force_try_count
        Rake.application = original_rake_application
    end

    # run_sync_requests の配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    it "別tokenのまま停止したSyncRequestをrakeのforce同期でElasticsearchへ反映する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "forcesynctoken",
            body:    "force sync body",
            status:  "published",
            user_id: 801,
        )

        sync_request = AreSearch::SyncRequest.find_by!(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document.id.to_s,
            sync_stage_name:     "default",
        )
        sync_request.update_columns(
            processing_token: "stopped-worker-token",
            processing_at:    1.hour.ago,
        )

        refresh_document_first_index
        before_result = search_document_first("forcesynctoken")
        expect(before_result.records).to eq([])

        load_run_sync_requests_task

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke("default")
        end.to output(
            /通常 0 件 強制 1 件/,
        ).to_stdout

        reloaded = AreSearch::SyncRequest.find(sync_request.id)

        expect(reloaded.force_attempted).to eq(true)
        expect(reloaded.force_try_count).to eq(1)
        expect(reloaded.last_force_try_at).not_to eq(nil)
        expect(reloaded.processing_token).to eq("stopped-worker-token")

        refresh_document_first_index
        after_result = search_document_first("forcesynctoken")

        expect(after_result.records.map(&:id)).to eq([document.id])
    end
end
