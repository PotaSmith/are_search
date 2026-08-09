# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch BulkIndexer recover integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    it "通常bulkでdata_failになったレコードを同じRESULT_DIRからrecoverする" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        failed_document = DocumentFirst.create!(
            title:   "bulkrecovertoken failed",
            body:    "recover target",
            status:  "published",
            user_id: 601,
        )
        success_document = DocumentFirst.create!(
            title:   "bulkrecovertoken success",
            body:    "normal target",
            status:  "published",
            user_id: 602,
        )

        fail_once = true

        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data_for_index!)
            .and_wrap_original do |original_method, *args|
                record = original_method.receiver

                if record.id == failed_document.id && fail_once
                    fail_once = false
                    raise RuntimeError, "intentional bulk recover test failure"
                end

                original_method.call(*args)
            end

        Dir.mktmpdir("are_search_bulk_recover_integration") do |result_dir|
            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            data_fail_file = File.join(
                result_dir,
                "data",
                "data_fail.log",
            )

            expect(File.read(data_fail_file)).to include(
                "#{failed_document.id} data_fail",
            )

            refresh_document_first_index

            before_recover = search_document_first("bulkrecovertoken")
            expect(before_recover.records.map(&:id)).to eq(
                [success_document.id],
            )

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
                recover:         true,
            )

            recover_success_file = File.join(
                result_dir,
                "recover",
                "recover_bulk_success.log",
            )

            expect(File.read(recover_success_file)).to include(
                "#{failed_document.id} success",
            )

            refresh_document_first_index

            after_recover = search_document_first("bulkrecovertoken")
            expect(after_recover.records.map(&:id).sort).to eq(
                [failed_document.id, success_document.id].sort,
            )
        end
    end
end
