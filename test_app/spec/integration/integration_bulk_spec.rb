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

    it "通常bulkの失敗をrecoverして退避し、同じRESULT_DIRで次の失敗もrecoverできる" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        first_failed_document = DocumentFirst.create!(
            title:   "bulkrecovertoken first failed",
            body:    "first recover target",
            status:  "published",
            user_id: 601,
        )
        success_document = DocumentFirst.create!(
            title:   "bulkrecovertoken success",
            body:    "normal target",
            status:  "published",
            user_id: 602,
        )

        fail_document_ids = [first_failed_document.id]
        failed_document_ids = []

        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data_for_index!)
            .and_wrap_original do |original_method, *args|
                record = original_method.receiver

                if fail_document_ids.include?(record.id) && failed_document_ids.include?(record.id) == false
                    failed_document_ids << record.id
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

            data_fail_file = File.join(result_dir, "data", "data_fail.log")
            expect(File.read(data_fail_file)).to include("#{first_failed_document.id} data_fail")

            refresh_document_first_index

            before_first_recover = search_document_first("bulkrecovertoken")
            expect(before_first_recover.records.map(&:id)).to eq([success_document.id])

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
                recover:         true,
            )

            first_archive_dirs = Dir.glob(File.join(result_dir, "recover_*"))
            expect(first_archive_dirs.length).to eq(1)
            expect(File.read(File.join(first_archive_dirs.first, "data_fail.log"))).to include(
                "#{first_failed_document.id} data_fail",
            )
            expect(File.read(File.join(first_archive_dirs.first, "recover_bulk_success.log"))).to include(
                "#{first_failed_document.id} success",
            )
            expect(File.exist?(data_fail_file)).to eq(false)

            second_failed_document = DocumentFirst.create!(
                title:   "bulkrecovertoken second failed",
                body:    "second recover target",
                status:  "published",
                user_id: 603,
            )
            fail_document_ids << second_failed_document.id

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            second_data_fail_log = File.read(data_fail_file)
            expect(second_data_fail_log).to include("#{second_failed_document.id} data_fail")
            expect(second_data_fail_log).not_to include("#{first_failed_document.id} data_fail")

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
                recover:         true,
            )

            archive_dirs = Dir.glob(File.join(result_dir, "recover_*"))
            expect(archive_dirs.length).to eq(2)
            expect(File.exist?(data_fail_file)).to eq(false)

            refresh_document_first_index

            after_recover = search_document_first("bulkrecovertoken")
            expect(after_recover.records.map(&:id).sort).to eq(
                [first_failed_document.id, success_document.id, second_failed_document.id].sort,
            )
        end
    end

    it "recoverで再失敗したIDを退避せず次のrecoverで再処理する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        failed_document = DocumentFirst.create!(
            title:   "bulkrecoverretrytoken failed",
            body:    "recover retry target",
            status:  "published",
            user_id: 604,
        )

        failed_count = 0

        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data_for_index!)
            .and_wrap_original do |original_method, *args|
                record = original_method.receiver

                if record.id == failed_document.id && failed_count < 2
                    failed_count += 1
                    raise RuntimeError, "intentional bulk recover retry test failure"
                end

                original_method.call(*args)
            end

        Dir.mktmpdir("are_search_bulk_recover_retry_integration") do |result_dir|
            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            data_fail_file = File.join(result_dir, "data", "data_fail.log")
            expect(File.read(data_fail_file)).to include("#{failed_document.id} data_fail")

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
                recover:         true,
            )

            recover_data_fail_file = File.join(result_dir, "recover", "recover_data_fail.log")
            expect(File.read(recover_data_fail_file)).to include("#{failed_document.id} data_fail")
            expect(Dir.glob(File.join(result_dir, "recover_*")).length).to eq(0)
            expect(File.exist?(data_fail_file)).to eq(true)

            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
                recover:         true,
            )

            expect(failed_count).to eq(2)

            archive_dirs = Dir.glob(File.join(result_dir, "recover_*"))
            expect(archive_dirs.length).to eq(1)
            expect(File.read(File.join(archive_dirs.first, "data_fail.log"))).to include(
                "#{failed_document.id} data_fail",
            )
            expect(File.read(File.join(archive_dirs.first, "recover_data_fail.log"))).to include(
                "#{failed_document.id} data_fail",
            )
            expect(File.read(File.join(archive_dirs.first, "recover_bulk_success.log"))).to include(
                "#{failed_document.id} success",
            )
            expect(File.exist?(data_fail_file)).to eq(false)
            expect(File.exist?(recover_data_fail_file)).to eq(false)
        end
    end
end

RSpec.describe "AreSearch BulkIndexer indexable integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        save_document_first_indexable_definition

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        example.run
    ensure
        restore_document_first_indexable_definition
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentFirstのare_search_indexable?差し替え前状態を退避する。
    def save_document_first_indexable_definition
        @document_first_indexable_direct = DocumentFirst.instance_methods(false).include?(:are_search_indexable?)

        if @document_first_indexable_direct
            DocumentFirst.send(
                :alias_method,
                :are_search_bulk_original_indexable,
                :are_search_indexable?,
            )
        end
    end

    # DocumentFirstのare_search_indexable?を元の定義へ戻す。
    def restore_document_first_indexable_definition
        if @document_first_indexable_direct
            DocumentFirst.send(
                :alias_method,
                :are_search_indexable?,
                :are_search_bulk_original_indexable,
            )
            DocumentFirst.send(:remove_method, :are_search_bulk_original_indexable)
            return
        end

        if DocumentFirst.instance_methods(false).include?(:are_search_indexable?)
            DocumentFirst.send(:remove_method, :are_search_indexable?)
        end
    end

    # statusがhiddenのレコードをBulkIndexerのindex対象外にする。
    def apply_hidden_document_indexable_definition
        DocumentFirst.send(
            :define_method,
            :are_search_indexable?,
        ) do |_index_target_name, _sync_stage_name|
            status != "hidden"
        end
    end

    it "are_search_indexable?がfalseのレコードをbulk deleteとして正常処理する" do
        apply_hidden_document_indexable_definition

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        excluded_document = DocumentFirst.create!(
            title:   "bulkdeletetoken hidden",
            body:    "hidden bulk body",
            status:  "hidden",
            user_id: 1601,
        )
        indexed_document = DocumentFirst.create!(
            title:   "bulkdeletetoken visible",
            body:    "visible bulk body",
            status:  "published",
            user_id: 1602,
        )

        Dir.mktmpdir("are_search_bulk_delete_integration") do |result_dir|
            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            success_file = File.join(result_dir, "data", "bulk_success.log")
            expect(File.read(success_file)).to include("#{excluded_document.id} success")
            expect(File.exist?(File.join(result_dir, "data", "data_skip.log"))).to eq(false)

            refresh_document_first_index
            result = search_document_first("bulkdeletetoken")
            expect(result.records.map(&:id)).to eq([indexed_document.id])
        end
    end

    it "既存ドキュメントがare_search_indexable?の対象外になった場合はbulkで削除する" do
        apply_hidden_document_indexable_definition

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        excluded_document = DocumentFirst.create!(
            title:   "bulkdeleteexistingtoken hidden",
            body:    "existing hidden bulk body",
            status:  "published",
            user_id: 1603,
        )
        indexed_document = DocumentFirst.create!(
            title:   "bulkdeleteexistingtoken visible",
            body:    "existing visible bulk body",
            status:  "published",
            user_id: 1604,
        )

        Dir.mktmpdir("are_search_bulk_delete_seed_integration") do |result_dir|
            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )
        end

        refresh_document_first_index
        before_result = search_document_first("bulkdeleteexistingtoken")
        expect(before_result.records.map(&:id).sort).to eq(
            [excluded_document.id, indexed_document.id].sort,
        )

        excluded_document.update!(status: "hidden")

        Dir.mktmpdir("are_search_bulk_delete_existing_integration") do |result_dir|
            document_first_index_target.are_search_bulk_index(
                "default",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )

            success_file = File.join(result_dir, "data", "bulk_success.log")
            expect(File.read(success_file)).to include("#{excluded_document.id} success")
        end

        refresh_document_first_index
        result = search_document_first("bulkdeleteexistingtoken")
        expect(result.records.map(&:id)).to eq([indexed_document.id])
    end
end
