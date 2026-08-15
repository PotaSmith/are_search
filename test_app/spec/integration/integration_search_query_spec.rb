# frozen_string_literal: true

require "rails_helper"
require "kaminari/helpers/helper_methods"
require_relative "../support/integration_support"

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

RSpec.describe "AreSearch search boundary integration", type: :model do
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

    # DocumentSecondのindexを現在定義から作り直す。
    def rebuild_index
        result = index_target.are_search_reindex(
            stage_position: :first,
        )

        expect(result[:result]).to eq(:success)
    end

    # integration specが作成したDB状態を削除する。
    def clear_records
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        AreSearch::SyncLock.delete_all
    end

    # DocumentSecondのindexをrefreshする。
    def refresh_index
        AreSearch.client.indices.refresh(
            index: index_target.are_search_index_alias_name,
        )
    end

    it "runtime_mappingsを実Elasticsearchで評価してresponse.fieldsへ返す" do
        document = DocumentSecond.create!(
            title:   "runtimeboundarytoken",
            body:    "runtime mapping integration",
            status:  "published",
            user_id: 1201,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "runtimeboundarytoken",
                    fields:       [:title],
                },
            ],
            runtime_mappings: {
                runtime_user_double: {
                    type: "long",
                    script: {
                        source: "emit(doc['user_id'].value * 2)",
                    },
                },
            },
            enable_runtime_mappings: true,
            response: {
                fields: ["runtime_user_double"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:fields][:runtime_user_double]).to eq([2402])
    end

    it "response.sourceに指定しても_sourceへ保存していないフィールドは返らない" do
        document = DocumentSecond.create!(
            title:   "missingresponseboundarytoken",
            body:    "not stored in source",
            status:  "published",
            user_id: 1203,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "missingresponseboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                source: ["body"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source]).not_to have_key(:body)
    end

    it "response.fieldsに指定しても_sourceへ保存していない通常フィールドは返らない" do
        document = DocumentSecond.create!(
            title:   "missingfieldsboundarytoken",
            body:    "not stored in source for fields",
            status:  "published",
            user_id: 1204,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "missingfieldsboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                fields: ["body"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:fields]).not_to have_key(:body)
    end

    it "response.stored_fieldsで_sourceへ保存していないstore済みフィールドを返す" do
        document = DocumentSecond.create!(
            title:   "storedfieldsboundarytoken",
            body:    "stored fields response body",
            status:  "published",
            user_id: 1205,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "storedfieldsboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                stored_fields: ["body"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source]).not_to have_key(:body)
        expect(hit[:fields][:body]).to eq([
            "stored fields response body",
        ])
    end

    it "response.docvalue_fieldsで_sourceへ保存していないdoc_valuesを返す" do
        document = DocumentSecond.create!(
            title:   "docvaluefieldsboundarytoken",
            body:    "docvalue fields response body",
            status:  "published",
            user_id: 1206,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "docvaluefieldsboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                docvalue_fields: ["user_id"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source]).not_to have_key(:user_id)
        expect(hit[:fields][:user_id]).to eq([1206])
    end

    it "response.sourceとresponse.fieldsを実Elasticsearchのhitから復元する" do
        document = DocumentSecond.create!(
            title:   "responseboundarytoken",
            body:    "stored response body",
            status:  "published",
            user_id: 1202,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "responseboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                source: ["title"],
                fields: ["status"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source][:title]).to eq("responseboundarytoken")
        expect(hit[:fields][:status]).to eq(["published"])
    end
end

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
        AreSearch::SyncLock.delete_all
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

    # ページング境界確認用のDocumentSecondをDBへ一括投入し、実indexへreindexする。
    def create_pagination_documents(count)
        now = Time.current
        rows = []

        (1..count).each do |user_id|
            rows << {
                title:      "paginationboundarytoken",
                body:       "pagination boundary body",
                status:     "published",
                user_id:    user_id,
                created_at: now,
                updated_at: now,
            }
        end

        DocumentSecond.insert_all!(rows)
        rebuild_index
        refresh_index
    end

    it "max_result_window境界まで実Elasticsearchで取得し境界以降は検索前に拒否する" do
        create_pagination_documents(2_001)

        crossing_result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "paginationboundarytoken",
                    fields:       [:title],
                },
            ],
            sort: {
                user_id: :asc,
            },
            page:     2,
            per_page: 1_500,
        )

        expect(crossing_result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(crossing_result.records.length).to eq(500)
        expect(crossing_result.records.first.user_id).to eq(1_501)
        expect(crossing_result.records.last.user_id).to eq(2_000)
        expect(crossing_result.records.es_total_count).to eq(2_001)
        expect(crossing_result.records.total_count).to eq(2_001)
        expect(crossing_result.records.pagination_total_count).to eq(2_000)
        expect(crossing_result.records.total_pages).to eq(2)
        expect(crossing_result.records.last_page?).to eq(true)
        expect(crossing_result.records.next_page).to eq(nil)

        edge_result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "paginationboundarytoken",
                    fields:       [:title],
                },
            ],
            sort: {
                user_id: :asc,
            },
            page:     2_000,
            per_page: 1,
        )

        expect(edge_result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(edge_result.records.map(&:user_id)).to eq([2_000])
        expect(edge_result.records.es_total_count).to eq(2_001)
        expect(edge_result.records.pagination_total_count).to eq(2_000)
        expect(edge_result.records.last_page?).to eq(true)
        expect(edge_result.records.next_page).to eq(nil)

        boundary_result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "paginationboundarytoken",
                    fields:       [:title],
                },
            ],
            page:     2_001,
            per_page: 1,
        )

        expect(boundary_result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(boundary_result.records).to eq([])

        over_result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "paginationboundarytoken",
                    fields:       [:title],
                },
            ],
            page:     2_002,
            per_page: 1,
        )

        expect(over_result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(over_result.records).to eq([])
    end

    it "PaginatedCollectionをKaminariのpaginateとpage_entries_infoへ渡せる" do
        create_pagination_documents(25)

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "paginationboundarytoken",
                    fields:       [:title],
                },
            ],
            sort: {
                user_id: :asc,
            },
            page:     2,
            per_page: 10,
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:user_id)).to eq((11..20).to_a)

        helper = double("kaminari_helper")
        helper.extend(Kaminari::Helpers::HelperMethods)

        paginator = double("paginator", to_s: "pagination")
        paginator_class = double("paginator_class")

        expect(paginator_class).to receive(:new).with(
            helper,
            total_pages:  3,
            current_page: 2,
            per_page:     10,
            remote:       false,
        ).and_return(paginator)

        expect(
            helper.paginate(result.records, paginator_class: paginator_class),
        ).to eq("pagination")

        expect(helper).to receive(:t).with(
            "helpers.page_entries_info.more_pages.display_entries",
            entry_name: anything,
            first:      11,
            last:       20,
            total:      25,
        ).and_return("page entries")

        expect(helper.page_entries_info(result.records)).to eq("page entries")
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

    it "More Like Thisでstore済みのfieldsを基準documentから取得して検索する" do
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
                fields: [:body],
                like: {
                    instance:     reference,
                    index_target: index_target,
                },
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

    it "More Like Thisで_sourceのfieldsを基準documentから取得して検索する" do
        reference = create_document(
            title:   "ruby rails elasticsearch search integration example",
            body:    "reference body",
            status:  "published",
            user_id: 909,
        )
        similar = create_document(
            title:   "ruby rails elasticsearch search integration guide",
            body:    "similar body",
            status:  "published",
            user_id: 910,
        )
        different = create_document(
            title:   "banana orange pineapple tropical fruit",
            body:    "different body",
            status:  "published",
            user_id: 911,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            mlt: {
                fields: [:title],
                like: {
                    instance:     reference,
                    index_target: index_target,
                },
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


RSpec.describe "AreSearch search DSL integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        rebuild_empty_document_first_index
        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # 検索用レコードを作成してElasticsearchへ反映する。
    def create_search_dsl_documents
        documents = [
            DocumentFirst.create!(
                title:   "searchdsl alpha rails",
                body:    "ruby elasticsearch",
                status:  "published",
                user_id: 1,
            ),
            DocumentFirst.create!(
                title:   "searchdsl beta rails",
                body:    "ruby database",
                status:  "draft",
                user_id: 2,
            ),
            DocumentFirst.create!(
                title:   "searchdsl gamma",
                body:    "elasticsearch database",
                status:  "published",
                user_id: 3,
            ),
        ]

        document_first_index_target.are_search_reindex(stage_position: :first)
        refresh_document_first_index

        documents
    end

    it "raw_bodyを実Elasticsearchへ渡してモデルを復元する" do
        documents = create_search_dsl_documents

        result = AreSearch::Searcher.search(
            [document_first_index_target],
            raw_body: {
                query: {
                    bool: {
                        must: [
                            { match: { title: "alpha" } },
                        ],
                    },
                },
            },
            build_model_bool: true,
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([documents[0].id])
    end

    it "simple_query_stringの演算子を実Elasticsearchで評価する" do
        documents = create_search_dsl_documents

        result = AreSearch::Searcher.search(
            [document_first_index_target],
            queries: [
                {
                    query_string: "rails + elasticsearch",
                    fields:       [:title, :body],
                    query_type:   AreSearch.query_type_simple_query_string,
                },
            ],
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([documents[0].id])
    end

    it "where系のterm、terms、rangeを組み合わせて実Elasticsearchで絞り込む" do
        documents = create_search_dsl_documents

        result = AreSearch::Searcher.search(
            [document_first_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
            ],
            where: {
                status: {
                    term: "published",
                },
            },
            where_not: {
                user_id: {
                    terms: [1],
                },
            },
            where_or: {
                user_id: {
                    range: {
                        gte: 3,
                        lte: 3,
                    },
                },
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([documents[2].id])
    end
end
