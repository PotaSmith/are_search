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

    it "model_relationsで除外した実Elasticsearchのhitを件数から補正する" do
        index_target = integration_index_target(DocumentFirst)

        reindex_results = reindex_integration_indexes([index_target])
        expect(reindex_results.first[:result]).to eq(:success)

        included = DocumentFirst.create!(
            title:   "relationcounttoken included",
            body:    "included relation count",
            status:  "visible",
            user_id: 831,
        )
        DocumentFirst.create!(
            title:   "relationcounttoken excluded",
            body:    "excluded relation count",
            status:  "hidden",
            user_id: 832,
        )

        refresh_integration_indexes([index_target])

        result = search_integration_index(
            index_target,
            "relationcounttoken",
            relation: DocumentFirst.where(status: "visible"),
            sort: {
                user_id: :asc,
            },
        )

        expect(result.raw_response.dig("hits", "total", "value")).to eq(2)
        expect(result.records.map(&:id)).to eq([included.id])
        expect(result.records.es_total_count).to eq(2)
        expect(result.records.total_count).to eq(1)
        expect(result.records.pagination_total_count).to eq(1)
    end

    it "DBから消えた実Elasticsearchのhitを件数から補正する" do
        index_target = integration_index_target(DocumentFirst)

        reindex_results = reindex_integration_indexes([index_target])
        expect(reindex_results.first[:result]).to eq(:success)

        stale = DocumentFirst.create!(
            title:   "missingdbcounttoken stale",
            body:    "stale count record",
            status:  "visible",
            user_id: 841,
        )
        existing = DocumentFirst.create!(
            title:   "missingdbcounttoken existing",
            body:    "existing count record",
            status:  "visible",
            user_id: 842,
        )

        refresh_integration_indexes([index_target])
        DocumentFirst.where(id: stale.id).delete_all

        result = search_integration_index(
            index_target,
            "missingdbcounttoken",
            sort: {
                user_id: :asc,
            },
        )

        expect(result.raw_response.dig("hits", "total", "value")).to eq(2)
        expect(result.records.map(&:id)).to eq([existing.id])
        expect(result.records.es_total_count).to eq(2)
        expect(result.records.total_count).to eq(1)
        expect(result.records.pagination_total_count).to eq(1)
    end

end

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
    it "同一IDのSTI子モデルを複数indexから検索して片方をmodel_relationsで除外してもhit対応を維持する" do
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

        excluded_first_child = DocumentFirstChild1.create!(
            id:      2101,
            title:   "stirelationtoken excluded first",
            body:    "excluded first child",
            status:  "hidden",
            user_id: 821,
        )
        second_same_id_child = DocumentSecondChild.create!(
            id:      2101,
            title:   "stirelationtoken second same id",
            body:    "second child same id",
            status:  "visible",
            user_id: 822,
        )
        included_first_child = DocumentFirstChild2.create!(
            id:      2102,
            title:   "stirelationtoken included first",
            body:    "included first child",
            status:  "visible",
            user_id: 823,
        )

        refresh_integration_indexes(index_targets)

        result = search_integration_indexes(
            index_targets,
            "stirelationtoken",
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
            excluded_first_child.id.to_s,
            second_same_id_child.id.to_s,
            included_first_child.id.to_s,
        )

        record_class_and_ids = result.records.map { |record|
            [record.class, record.id]
        }
        expect(record_class_and_ids).to eq([
            [DocumentSecondChild, second_same_id_child.id],
            [DocumentFirstChild2, included_first_child.id],
        ])

        record_and_hit_ids = result.records_with_hit.map { |record, hit|
            [record.class, record.id.to_s, hit[:id]]
        }
        expect(record_and_hit_ids).to eq([
            [DocumentSecondChild, second_same_id_child.id.to_s, second_same_id_child.id.to_s],
            [DocumentFirstChild2, included_first_child.id.to_s, included_first_child.id.to_s],
        ])
    end

end

RSpec.describe "AreSearch multi index response integration", type: :model do
    self.use_transactional_tests = false

    before(:context) do
        @original_after_commit_mode = AreSearch.after_commit_mode
        @original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true

        clear_multi_index_response_records

        @first_index_target = DocumentFirst.are_search_index_target(:default)
        @second_index_target = DocumentSecond.are_search_index_target(:default)

        first_reindex_result = @first_index_target.are_search_reindex(
            stage_position: :first,
        )
        second_reindex_result = @second_index_target.are_search_reindex(
            stage_position: :first,
        )

        raise "DocumentFirst reindex failed" if first_reindex_result[:result] != :success
        raise "DocumentSecond reindex failed" if second_reindex_result[:result] != :success

        DocumentFirst.create!(
            title:   "multiresponseintegrationtoken first",
            body:    "first body",
            status:  "published",
            user_id: 1301,
        )
        DocumentSecond.create!(
            title:   "multiresponseintegrationtoken second",
            body:    "second body",
            status:  "published",
            user_id: 1302,
        )

        refresh_multi_index_response_indices
    end

    after(:context) do
        clear_multi_index_response_records

        AreSearch.after_commit_mode = @original_after_commit_mode
        AreSearch.index_operation_enabled = @original_index_operation_enabled
    end

    # このspecで使用するDBレコードと同期状態を削除する。
    def clear_multi_index_response_records
        DocumentFirst.delete_all
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        AreSearch::SyncLock.delete_all
    end

    # 2つの検索対象indexをrefreshする。
    def refresh_multi_index_response_indices
        AreSearch.client.indices.refresh(
            index: @first_index_target.are_search_index_alias_name,
        )
        AreSearch.client.indices.refresh(
            index: @second_index_target.are_search_index_alias_name,
        )
    end

    # 指定したresponse取得方法とfieldで2indexを同時検索して、モデル別のhitを返す。
    def search_multi_index_response(response_key, field_name)
        result = AreSearch::Searcher.search(
            [
                @first_index_target,
                @second_index_target,
            ],
            queries: [
                {
                    query_string: "multiresponseintegrationtoken",
                    fields:       [:title],
                },
            ],
            response: {
                response_key => [field_name],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:class).sort_by(&:name)).to eq(
            [DocumentFirst, DocumentSecond],
        )

        hits = {}
        result.records_with_hit.each do |record, hit|
            hits[record.class] = hit
        end

        hits
    end

    describe "response.source" do
        it "両indexにあるfieldは両方の_sourceから返す" do
            hits = search_multi_index_response(
                :source,
                "multi_response_both",
            )

            expect(
                hits[DocumentFirst][:source][:multi_response_both],
            ).to eq("first both")
            expect(
                hits[DocumentSecond][:source][:multi_response_both],
            ).to eq("second both")
        end

        it "FirstだけにあるfieldはFirstの_sourceだけから返す" do
            hits = search_multi_index_response(
                :source,
                "multi_response_first_only",
            )

            expect(
                hits[DocumentFirst][:source][:multi_response_first_only],
            ).to eq("first only")
            expect(
                hits[DocumentSecond][:source],
            ).not_to have_key(:multi_response_first_only)
        end

        it "SecondだけにあるfieldはSecondの_sourceだけから返す" do
            hits = search_multi_index_response(
                :source,
                "multi_response_second_only",
            )

            expect(
                hits[DocumentFirst][:source],
            ).not_to have_key(:multi_response_second_only)
            expect(
                hits[DocumentSecond][:source][:multi_response_second_only],
            ).to eq("second only")
        end

        it "どちらのindexにも無いfieldはどちらの_sourceにも返さない" do
            hits = search_multi_index_response(
                :source,
                "multi_response_neither",
            )

            expect(
                hits[DocumentFirst][:source],
            ).not_to have_key(:multi_response_neither)
            expect(
                hits[DocumentSecond][:source],
            ).not_to have_key(:multi_response_neither)
        end
    end

    describe "response.fields" do
        it "両indexにあるfieldは両方のfieldsから返す" do
            hits = search_multi_index_response(
                :fields,
                "multi_response_both",
            )

            expect(
                hits[DocumentFirst][:fields][:multi_response_both],
            ).to eq(["first both"])
            expect(
                hits[DocumentSecond][:fields][:multi_response_both],
            ).to eq(["second both"])
        end

        it "FirstだけにあるfieldはFirstのfieldsだけから返す" do
            hits = search_multi_index_response(
                :fields,
                "multi_response_first_only",
            )

            expect(
                hits[DocumentFirst][:fields][:multi_response_first_only],
            ).to eq(["first only"])
            expect(
                hits[DocumentSecond][:fields],
            ).not_to have_key(:multi_response_first_only)
        end

        it "SecondだけにあるfieldはSecondのfieldsだけから返す" do
            hits = search_multi_index_response(
                :fields,
                "multi_response_second_only",
            )

            expect(
                hits[DocumentFirst][:fields],
            ).not_to have_key(:multi_response_second_only)
            expect(
                hits[DocumentSecond][:fields][:multi_response_second_only],
            ).to eq(["second only"])
        end

        it "どちらのindexにも無いfieldはどちらのfieldsにも返さない" do
            hits = search_multi_index_response(
                :fields,
                "multi_response_neither",
            )

            expect(
                hits[DocumentFirst][:fields],
            ).not_to have_key(:multi_response_neither)
            expect(
                hits[DocumentSecond][:fields],
            ).not_to have_key(:multi_response_neither)
        end
    end

    describe "response.stored_fields" do
        it "両indexにあるfieldは両方のstored_fieldsから返す" do
            hits = search_multi_index_response(
                :stored_fields,
                "multi_response_both",
            )

            expect(
                hits[DocumentFirst][:fields][:multi_response_both],
            ).to eq(["first both"])
            expect(
                hits[DocumentSecond][:fields][:multi_response_both],
            ).to eq(["second both"])
        end

        it "FirstだけにあるfieldはFirstのstored_fieldsだけから返す" do
            hits = search_multi_index_response(
                :stored_fields,
                "multi_response_first_only",
            )

            expect(
                hits[DocumentFirst][:fields][:multi_response_first_only],
            ).to eq(["first only"])
            expect(
                hits[DocumentSecond][:fields],
            ).not_to have_key(:multi_response_first_only)
        end

        it "SecondだけにあるfieldはSecondのstored_fieldsだけから返す" do
            hits = search_multi_index_response(
                :stored_fields,
                "multi_response_second_only",
            )

            expect(
                hits[DocumentFirst][:fields],
            ).not_to have_key(:multi_response_second_only)
            expect(
                hits[DocumentSecond][:fields][:multi_response_second_only],
            ).to eq(["second only"])
        end

        it "どちらのindexにも無いfieldはどちらのstored_fieldsにも返さない" do
            hits = search_multi_index_response(
                :stored_fields,
                "multi_response_neither",
            )

            expect(
                hits[DocumentFirst][:fields],
            ).not_to have_key(:multi_response_neither)
            expect(
                hits[DocumentSecond][:fields],
            ).not_to have_key(:multi_response_neither)
        end
    end

    describe "response.docvalue_fields" do
        it "両indexにあるfieldは両方のdocvalue_fieldsから返す" do
            hits = search_multi_index_response(
                :docvalue_fields,
                "multi_response_both",
            )

            expect(
                hits[DocumentFirst][:fields][:multi_response_both],
            ).to eq(["first both"])
            expect(
                hits[DocumentSecond][:fields][:multi_response_both],
            ).to eq(["second both"])
        end

        it "FirstだけにあるfieldはFirstのdocvalue_fieldsだけから返す" do
            hits = search_multi_index_response(
                :docvalue_fields,
                "multi_response_first_only",
            )

            expect(
                hits[DocumentFirst][:fields][:multi_response_first_only],
            ).to eq(["first only"])
            expect(
                hits[DocumentSecond][:fields],
            ).not_to have_key(:multi_response_first_only)
        end

        it "SecondだけにあるfieldはSecondのdocvalue_fieldsだけから返す" do
            hits = search_multi_index_response(
                :docvalue_fields,
                "multi_response_second_only",
            )

            expect(
                hits[DocumentFirst][:fields],
            ).not_to have_key(:multi_response_second_only)
            expect(
                hits[DocumentSecond][:fields][:multi_response_second_only],
            ).to eq(["second only"])
        end

        it "どちらのindexにも無いfieldはどちらのdocvalue_fieldsにも返さない" do
            hits = search_multi_index_response(
                :docvalue_fields,
                "multi_response_neither",
            )

            expect(
                hits[DocumentFirst][:fields],
            ).not_to have_key(:multi_response_neither)
            expect(
                hits[DocumentSecond][:fields],
            ).not_to have_key(:multi_response_neither)
        end
    end
end

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
