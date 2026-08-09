# frozen_string_literal: true

require "rails_helper"
require_relative "../support/integration_support"

RSpec.describe "AreSearch relation search integration", type: :model do
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

    it "relationで中央のhitを除外してもrecords_with_hitの対応を維持する" do
        index_target = integration_index_target(DocumentFirst)

        reindex_results = reindex_integration_indexes([index_target])
        expect(reindex_results.first[:result]).to eq(:success)

        first = DocumentFirst.create!(
            title:   "relationordertoken first",
            body:    "relation first",
            status:  "visible",
            user_id: 801,
        )
        middle = DocumentFirst.create!(
            title:   "relationordertoken middle",
            body:    "relation middle",
            status:  "hidden",
            user_id: 802,
        )
        last = DocumentFirst.create!(
            title:   "relationordertoken last",
            body:    "relation last",
            status:  "visible",
            user_id: 803,
        )

        refresh_integration_indexes([index_target])

        result = search_integration_index(
            index_target,
            "relationordertoken",
            relation: DocumentFirst.where(status: "visible"),
            sort: {
                user_id: :asc,
            },
        )

        raw_hit_ids = result.raw_response.dig("hits", "hits").map { |hit| hit["_id"] }
        expect(raw_hit_ids).to eq([
            first.id.to_s,
            middle.id.to_s,
            last.id.to_s,
        ])

        expect(result.records.map(&:id)).to eq([
            first.id,
            last.id,
        ])

        record_and_hit_ids = result.records_with_hit.map { |record, hit|
            [record.id.to_s, hit[:id]]
        }
        expect(record_and_hit_ids).to eq([
            [first.id.to_s, first.id.to_s],
            [last.id.to_s, last.id.to_s],
        ])
    end

    it "片方のmodel_relationsで同じIDを除外しても別モデルの同じIDを残す" do
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

        excluded_first = DocumentFirst.create!(
            id:      2001,
            title:   "relationmultitoken excluded first",
            body:    "excluded first model",
            status:  "hidden",
            user_id: 811,
        )
        second_same_id = DocumentSecond.create!(
            id:      2001,
            title:   "relationmultitoken second",
            body:    "second model",
            status:  "visible",
            user_id: 812,
        )
        included_first = DocumentFirst.create!(
            id:      2002,
            title:   "relationmultitoken included first",
            body:    "included first model",
            status:  "visible",
            user_id: 813,
        )

        refresh_integration_indexes(index_targets)

        result = search_integration_indexes(
            index_targets,
            "relationmultitoken",
            model_relations: {
                DocumentFirst => DocumentFirst.where(status: "visible"),
            },
            sort: {
                user_id: :asc,
            },
        )

        raw_hits = result.raw_response.dig("hits", "hits")
        expect(raw_hits.length).to eq(3)
        expect(raw_hits.map { |hit| hit["_id"] }).to include(
            excluded_first.id.to_s,
            second_same_id.id.to_s,
            included_first.id.to_s,
        )

        record_class_and_ids = result.records.map { |record|
            [record.class, record.id]
        }
        expect(record_class_and_ids).to eq([
            [DocumentSecond, second_same_id.id],
            [DocumentFirst, included_first.id],
        ])

        record_and_hit_ids = result.records_with_hit.map { |record, hit|
            [record.class, record.id.to_s, hit[:id]]
        }
        expect(record_and_hit_ids).to eq([
            [DocumentSecond, second_same_id.id.to_s, second_same_id.id.to_s],
            [DocumentFirst, included_first.id.to_s, included_first.id.to_s],
        ])
    end

    it "DBから消えたレコードがESに残っていてもrecordsへ混ぜない" do
        index_target = integration_index_target(DocumentFirst)

        reindex_results = reindex_integration_indexes([index_target])
        expect(reindex_results.first[:result]).to eq(:success)

        stale = DocumentFirst.create!(
            title:   "missingdbtoken stale",
            body:    "stale record",
            status:  "visible",
            user_id: 821,
        )
        existing = DocumentFirst.create!(
            title:   "missingdbtoken existing",
            body:    "existing record",
            status:  "visible",
            user_id: 822,
        )

        refresh_integration_indexes([index_target])

        DocumentFirst.where(id: stale.id).delete_all

        result = search_integration_index(
            index_target,
            "missingdbtoken",
            sort: {
                user_id: :asc,
            },
        )

        raw_hit_ids = result.raw_response.dig("hits", "hits").map { |hit| hit["_id"] }
        expect(raw_hit_ids).to eq([
            stale.id.to_s,
            existing.id.to_s,
        ])

        expect(result.records.map(&:id)).to eq([
            existing.id,
        ])

        record_and_hit_ids = result.records_with_hit.map { |record, hit|
            [record.id.to_s, hit[:id]]
        }
        expect(record_and_hit_ids).to eq([
            [existing.id.to_s, existing.id.to_s],
        ])
    end
end
