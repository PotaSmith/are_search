# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch search features integration", type: :model do
    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true

        clear_records
        rebuild_index

        example.run
    ensure
        clear_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentSecondの標準IndexTargetを返す。
    def index_target
        DocumentSecond.are_search_index_target(:default)
    end

    # DBを空にしてDocumentSecondのindexを作り直す。
    def rebuild_index
        result = index_target.are_search_reindex(
            stage_position: :first,
        )

        expect(result[:result]).to eq(:success)
    end

    # DocumentSecondと同期要求を削除する。
    def clear_records
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        AreSearch::IndexMarker.delete_all
    end

    # DocumentSecondのindexをrefreshする。
    def refresh_index
        AreSearch.client.indices.refresh(
            index: index_target.are_search_index_alias_name,
        )
    end

    # 指定値でDocumentSecondを作成する。
    def create_document(title:, body:, status:, user_id:)
        DocumentSecond.create!(
            title:   title,
            body:    body,
            status:  status,
            user_id: user_id,
        )
    end

    it "storeを指定していないtextフィールドを通常検索できる" do
        document = create_document(
            title:   "nostoretitle token",
            body:    "ordinary body",
            status:  "published",
            user_id: 901,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "nostoretitle",
                    fields:       [:title],
                },
            ],
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])
    end

    it "ドキュメント記載のaggregation形式でstoreなしkeywordを集計できる" do
        create_document(
            title:   "published one",
            body:    "aggregation body one",
            status:  "published",
            user_id: 902,
        )
        create_document(
            title:   "published two",
            body:    "aggregation body two",
            status:  "published",
            user_id: 903,
        )
        create_document(
            title:   "draft one",
            body:    "aggregation body three",
            status:  "draft",
            user_id: 904,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
            ],
            aggs: {
                status_count: {
                    terms: {
                        field: :status,
                        size:  20,
                    },
                },
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.aggs(:status_count)).to eq([
            ["published", 2],
            ["draft", 1],
        ])
    end

    it "ドキュメント記載のhighlight形式でstoreありtextの一致部分を返す" do
        document = create_document(
            title:   "highlight document",
            body:    "before highlighttoken after",
            status:  "published",
            user_id: 905,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "highlighttoken",
                    fields:       [:body],
                },
            ],
            highlight: {
                fields: {
                    body: {
                        fragment_size:       200,
                        number_of_fragments: 3,
                    },
                },
                type:                "unified",
                require_field_match: false,
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first

        expect(record.id).to eq(document.id)
        expect(hit[:highlight][:body]).not_to eq(nil)
        expect(
            hit[:highlight][:body].join(" "),
        ).to include("<em>highlighttoken</em>")
    end

    it "ドキュメント記載のMore Like This形式でstoreありtextから類似文書を検索する" do
        reference = create_document(
            title:   "reference",
            body:    "ruby rails elasticsearch search integration example",
            status:  "published",
            user_id: 906,
        )
        similar = create_document(
            title:   "similar",
            body:    "ruby rails elasticsearch search integration guide",
            status:  "published",
            user_id: 907,
        )
        different = create_document(
            title:   "different",
            body:    "banana orange pineapple tropical fruit",
            status:  "published",
            user_id: 908,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            mlt: {
                instance:             reference,
                index_target:         index_target,
                fields:               [:body],
                min_term_freq:        1,
                min_doc_freq:         1,
                max_query_terms:      20,
                min_word_length:      2,
                minimum_should_match: "30%",
                boost_terms:          1.5,
            },
        )

        result_ids = result.records.map(&:id)

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result_ids).to include(similar.id)
        expect(result_ids).not_to include(different.id)
    end
end
