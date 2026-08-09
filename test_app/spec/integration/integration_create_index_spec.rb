# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch create index integration", type: :model do
    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        delete_document_second_physical_indexes

        example.run
    ensure
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        delete_document_second_physical_indexes

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentSecondのaliasから生成された物理indexを削除する。
    def delete_document_second_physical_indexes
        index_target = DocumentSecond.are_search_index_target(:default)
        response = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: index_target.are_search_index_alias_name,
        )

        response.keys.each do |physical_index_name|
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end
    end

    it "DBにレコードがあっても空indexを作成してaliasを接続する" do
        document = DocumentSecond.create!(
            title:   "createindextoken",
            body:    "create index body",
            status:  "published",
            user_id: 501,
        )

        index_target = DocumentSecond.are_search_index_target(:default)

        expect(index_target.are_search_index_alias_exists?).to eq(false)

        result = index_target.are_search_create_index

        expect(result[:result]).to eq(:success)
        expect(index_target.are_search_index_alias_exists?).to eq(true)

        physical_index_names = AreSearch::IndexManager.physical_index_names_by_alias(
            index_target.are_search_index_alias_name,
        )
        expect(physical_index_names.length).to eq(1)

        count_response = AreSearch.client.count(
            index: index_target.are_search_index_alias_name,
        )

        expect(count_response["count"]).to eq(0)
        expect(DocumentSecond.exists?(document.id)).to eq(true)
    end
end
