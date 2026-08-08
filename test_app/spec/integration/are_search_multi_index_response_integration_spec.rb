# frozen_string_literal: true

require "rails_helper"

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

        raise "DocumentFirst reindex failed" unless first_reindex_result[:result] == :success
        raise "DocumentSecond reindex failed" unless second_reindex_result[:result] == :success

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
        AreSearch::IndexMarker.delete_all
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
