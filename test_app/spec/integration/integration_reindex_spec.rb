# frozen_string_literal: true

require "rails_helper"
require_relative "../support/integration_support"

RSpec.describe "AreSearch reindex integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        delete_document_first_physical_indexes
        example.run
    ensure
        clear_are_search_integration_records
        delete_document_first_physical_indexes

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentFirstのaliasから生成された物理indexをすべて削除する。
    def delete_document_first_physical_indexes
        response = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: document_first_index_target.are_search_index_alias_name,
        )

        response.keys.each do |physical_index_name|
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end
    end

    it "reindexを2回実行した後clean_upで旧物理indexだけを削除する" do
        first_result = rebuild_empty_document_first_index
        expect(first_result[:result]).to eq(:success)

        first_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(first_physical_names.length).to eq(1)

        DocumentFirst.create!(
            title:   "reindexlifecycletoken",
            body:    "second reindex body",
            status:  "published",
            user_id: 1001,
        )

        second_result = document_first_index_target.are_search_reindex(
            stage_position: :first,
        )
        expect(second_result[:result]).to eq(:success)

        second_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(second_physical_names.length).to eq(1)
        expect(second_physical_names).not_to eq(first_physical_names)

        all_physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: document_first_index_target.are_search_index_alias_name,
        ).keys
        expect(all_physical_names.sort).to eq(
            (first_physical_names + second_physical_names).sort,
        )

        clean_up_result = AreSearch::IndexManager.index_clean_up(
            document_first_index_target.are_search_index_alias_name,
        )

        expect(clean_up_result[:result]).to eq(:success)
        expect(clean_up_result[:delete_index_names]).to eq(first_physical_names)
        expect(
            AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: document_first_index_target.are_search_index_alias_name,
            ).keys,
        ).to eq(second_physical_names)
    end

    it "実Elasticsearchのbulk部分失敗時はfailed_idsを返してaliasを切り替えない" do
        first_result = rebuild_empty_document_first_index
        expect(first_result[:result]).to eq(:success)

        old_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(old_physical_names.length).to eq(1)

        success_document = DocumentFirst.create!(
            title:   "reindexfailuretoken success",
            body:    "valid document",
            status:  "published",
            user_id: 1002,
        )
        failed_document = DocumentFirst.create!(
            title:   "reindexfailuretoken failed",
            body:    "invalid long document",
            status:  "published",
            user_id: 1003,
        )

        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data)
            .and_wrap_original do |original_method, *args|
                data = original_method.call(*args)
                record = original_method.receiver

                if record.id == failed_document.id
                    data[:user_id] = 10 ** 30
                end

                data
            end

        result = document_first_index_target.are_search_reindex(
            stage_position: :first,
        )

        expect(result[:result]).to eq(:not_success)
        expect(result[:failed_ids]).to eq([failed_document.id])
        expect(result[:stop_phase]).to eq(:index_to_new_index)
        expect(result[:done_phases]).to include(
            :lock_index,
            :create_marker,
            :create_new_index,
        )
        expect(result[:done_phases]).not_to include(:switch_alias)

        current_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(current_physical_names).to eq(old_physical_names)

        all_physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: document_first_index_target.are_search_index_alias_name,
        ).keys
        expect(all_physical_names.length).to eq(2)

        refresh_document_first_index
        search_result = search_document_first("reindexfailuretoken")
        expect(search_result.records).to eq([])

        expect(DocumentFirst.exists?(success_document.id)).to eq(true)
        expect(DocumentFirst.exists?(failed_document.id)).to eq(true)
    end
end
