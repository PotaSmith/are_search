# frozen_string_literal: true

require "rails_helper"
require_relative "../support/are_search_integration_support"

RSpec.describe "AreSearch multiple model search integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        with_are_search_integration_settings(
            after_commit_mode: :direct,
            index_operation_enabled: true,
        ) do
            begin
                clear_are_search_integration_records(
                    [DocumentFirst, DocumentSecond],
                )

                example.run
            ensure
                clear_are_search_integration_records(
                    [DocumentFirst, DocumentSecond],
                )
            end
        end
    end

    it "異なるモデルの同じIDをそれぞれ正しいActiveRecordへ復元する" do
        first_index_target = integration_index_target(DocumentFirst)
        second_index_target = integration_index_target(DocumentSecond)
        index_targets = [
            first_index_target,
            second_index_target,
        ]

        reindex_results = reindex_integration_indexes(index_targets)
        expect(
            reindex_results.map { |result| result[:result] },
        ).to eq([
            :success,
            :success,
        ])

        first_document = DocumentFirst.create!(
            id:      1001,
            title:   "multimodeltoken first",
            body:    "first model",
            status:  "published",
            user_id: 701,
        )
        second_document = DocumentSecond.create!(
            id:      1001,
            title:   "multimodeltoken second",
            body:    "second model",
            status:  "published",
            user_id: 702,
        )

        refresh_integration_indexes(index_targets)

        result = search_integration_indexes(
            index_targets,
            "multimodeltoken",
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:class).sort_by(&:name)).to eq(
            [DocumentFirst, DocumentSecond],
        )
        expect(result.records.map(&:id)).to eq(
            [first_document.id, second_document.id],
        )
        expect(result.records.map(&:title).sort).to eq(
            [
                "multimodeltoken first",
                "multimodeltoken second",
            ],
        )
    end

    it "異なる継承系統の子モデルが同じIDでもそれぞれ正しい子クラスへ復元する" do
        first_index_target = integration_index_target(DocumentFirst)
        second_index_target = integration_index_target(DocumentSecond)
        index_targets = [
            first_index_target,
            second_index_target,
        ]

        reindex_results = reindex_integration_indexes(index_targets)
        expect(
            reindex_results.map { |result| result[:result] },
        ).to eq([
            :success,
            :success,
        ])

        first_child = DocumentFirstChild1.create!(
            id:      1001,
            title:   "multichildtoken first child",
            body:    "first child model",
            status:  "published",
            user_id: 703,
        )
        second_child = DocumentSecondChild.create!(
            id:      1001,
            title:   "multichildtoken second child",
            body:    "second child model",
            status:  "published",
            user_id: 704,
        )

        refresh_integration_indexes(index_targets)

        result = search_integration_indexes(
            index_targets,
            "multichildtoken",
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:class).sort_by(&:name)).to eq(
            [DocumentFirstChild1, DocumentSecondChild],
        )
        expect(result.records.map(&:id)).to eq(
            [first_child.id, second_child.id],
        )
        expect(result.records.map(&:title).sort).to eq(
            [
                "multichildtoken first child",
                "multichildtoken second child",
            ],
        )
    end
end
