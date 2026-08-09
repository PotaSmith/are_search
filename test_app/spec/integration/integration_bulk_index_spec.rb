# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch BulkIndexer integration", type: :model do
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

    it "通常bulk投入後に同じRESULT_DIRからcheckpoint以降を再開できる" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        first = DocumentFirst.create!(
            title:   "bulksharedtoken first",
            body:    "first bulk body",
            status:  "published",
            user_id: 401,
        )
        second = DocumentFirst.create!(
            title:   "bulksharedtoken second",
            body:    "second bulk body",
            status:  "published",
            user_id: 402,
        )

        Dir.mktmpdir("are_search_bulk_integration") do |result_dir|
            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            refresh_document_first_index

            first_result = search_document_first("bulksharedtoken")
            expect(first_result.records.map(&:id).sort).to eq(
                [first.id, second.id].sort,
            )

            data_dir = File.join(result_dir, "data")
            check_point_file = File.join(data_dir, "check_point.log")
            success_file = File.join(data_dir, "bulk_success.log")
            bulk_log_file = File.join(result_dir, "bulk.log")

            expect(File.file?(check_point_file)).to eq(true)
            expect(File.file?(success_file)).to eq(true)
            expect(File.file?(bulk_log_file)).to eq(true)

            first_success_log = File.read(success_file)
            expect(first_success_log).to include("#{first.id} success")
            expect(first_success_log).to include("#{second.id} success")

            third = DocumentFirst.create!(
                title:   "bulksharedtoken third",
                body:    "third bulk body",
                status:  "published",
                user_id: 403,
            )

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            refresh_document_first_index

            second_result = search_document_first("bulksharedtoken")
            expect(second_result.records.map(&:id).sort).to eq(
                [first.id, second.id, third.id].sort,
            )

            check_point_log = File.read(check_point_file)
            expect(check_point_log).to include("#{third.id} check_point")

            success_log = File.read(success_file)
            expect(success_log.scan("#{first.id} success").length).to eq(1)
            expect(success_log.scan("#{second.id} success").length).to eq(1)
            expect(success_log.scan("#{third.id} success").length).to eq(1)
        end
    end
end
