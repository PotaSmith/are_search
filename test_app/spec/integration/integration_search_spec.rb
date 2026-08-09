# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch search", type: :model do
    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true

        DocumentFirst.delete_all
        AreSearch::SyncRequest.delete_all

        example.run
    ensure
        DocumentFirst.delete_all
        AreSearch::SyncRequest.delete_all

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    it "登録したDocumentFirstを検索できる" do
        index_target = DocumentFirst.are_search_index_target(:default)

        reindex_result = index_target.are_search_reindex(
            stage_position: :first,
        )

        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "are search integration test",
            body:    "searchable document body",
            status:  "published",
            user_id: 123,
        )

        # Elasticsearchのrefresh待ちでテスト結果が揺れないよう明示的にrefreshする。
        AreSearch.client.indices.refresh(
            index: index_target.are_search_index_alias_name,
        )

        result = index_target.are_search_search(
            "integration",
            fields: [:title, :body],
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])
        expect(result.records.first).to be_a(DocumentFirst)
    end
end
