# frozen_string_literal: true

require "rails_helper"
require_relative "../support/integration_support"

RSpec.describe "AreSearch STI integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    it "親IndexTargetではSTI子クラスをまとめて検索し子IndexTargetでは対象の子だけ検索する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        child1 = DocumentFirstChild1.create!(
            title:   "sharedstitoken child1",
            body:    "child one",
            status:  "published",
            user_id: 101,
        )
        child2 = DocumentFirstChild2.create!(
            title:   "sharedstitoken child2",
            body:    "child two",
            status:  "published",
            user_id: 102,
        )

        refresh_document_first_index

        parent_result = search_document_first("sharedstitoken")

        expect(parent_result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(parent_result.records.map(&:id).sort).to eq(
            [child1.id, child2.id].sort,
        )
        expect(parent_result.records.map(&:class).sort_by(&:name)).to eq(
            [DocumentFirstChild1, DocumentFirstChild2],
        )

        child1_index_target = DocumentFirstChild1.are_search_index_target(:default)
        child1_result = search_document_first(
            "sharedstitoken",
            index_target: child1_index_target,
        )

        expect(child1_result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(child1_result.records.map(&:id)).to eq([child1.id])
        expect(child1_result.records.first).to be_a(DocumentFirstChild1)
    end
end
