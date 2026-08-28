# frozen_string_literal: true

require "spec_helper"

RSpec.describe "search paging" do
    let(:article_mappings) do
        {
            properties: {
                title: { type: "text" },
            },
        }
    end
    let(:document_mappings) do
        {
            properties: {
                title: { type: "text" },
            },
        }
    end
    let(:article_model) do
        Class.new do
            attr_reader :id

            def self.name
                "Article"
            end

            def self.are_search_ar_table_name
                "articles"
            end

            def self.default_properties
                {
                    title: { type: "text" },
                }
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            # 実際のSearchableモデルと同じ入口からIndexTargetを解決する。
            def self.are_search_index_target(index_target_name)
                AreSearch::IndexTarget.new(self, index_target_name)
            end

            def initialize(id = 1)
                @id = id
            end
        end
    end
    let(:document_model) do
        Class.new do
            def self.name
                "Document"
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end
        end
    end
    let(:article) do
        article_model.new
    end
    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                       article_model,
            index_target_name:                       :default,
            are_search_index_alias_name:          "test__articles__default",
            are_search_index_alias_exists?: true,
            are_search_index_mappings:            article_mappings,
            are_search_index_settings: article_index_settings,
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                       document_model,
            index_target_name:                       :default,
            are_search_index_alias_name:          "test__documents__default",
            are_search_index_alias_exists?: true,
            are_search_index_mappings:            document_mappings,
            are_search_index_settings: document_index_settings,
        )
    end
    let(:article_index_settings) do
        { max_result_window: 30 }
    end
    let(:document_index_settings) do
        { max_result_window: 50 }
    end

    around do |example|
        original_searchable_class_setting = AreSearch.searchable_class_setting
        AreSearch.searchable_class_setting = {
            "Article" => {
                default: {
                    settings: {
                        max_result_window: 30,
                    },
                    mappings: {
                        _source: {
                            includes: [:title],
                        },
                    },
                    properties_method: :default_properties,
                },
            },
        }

        example.run
    ensure
        AreSearch.searchable_class_setting = original_searchable_class_setting
    end

    before do
        allow(AreSearch::EsAdapter)
            .to receive(:index_alias_exists?)
            .with(index_alias_name: "test__articles__default")
            .and_return(true)

        allow(AreSearch::EsAdapter)
            .to receive(:index_alias_exists?)
            .with(index_alias_name: "test__documents__default")
            .and_return(true)
    end

    it "単一 target は max_result_window を超える最後のページの size を縮める" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:    [:title],
                },
            ],
            page:      2,
            per_page:  20,
            dump_body: true,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "複数 target は最小の max_result_window で size を縮める" do
        body = AreSearch::Searcher.search(
            [article_index_target, document_index_target],
            queries: [
                {
                    query_string: "",
                    fields:    [:title],
                },
            ],
            page:      2,
            per_page:  20,
            dump_body: true,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "More Like This検索も基準IndexTargetのmax_result_window内へ収める" do
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")

        mlt_index_target = AreSearch::IndexTarget.new(article_model, :default)

        body = AreSearch::Searcher.search(
            [mlt_index_target],
            mlt: {
                fields: [:title],
                like: {
                    instance:     article,
                    index_target: mlt_index_target,
                },
            },
            page:             2,
            per_page:         20,
            dump_body:        true,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "開始位置がmax_result_window以上なら検索前にparams_invalidにする" do
        expect(AreSearch::EsAdapter).not_to receive(:no_validation_search)

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
            },
            page:     3,
            per_page: 20,
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(result.records).to eq([])
    end

    it "ES総件数がmax_result_windowを超えてもページング可能件数は上限内にする" do
        response = {
            "hits" => {
                "hits"  => [],
                "total" => { "value" => 100 },
            },
        }

        allow(AreSearch::EsAdapter)
            .to receive(:no_validation_search)
            .and_return(response)

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
            },
            page:     1,
            per_page: 20,
        )

        expect(result.total_count).to eq(100)
        expect(result.records.total_count).to eq(100)
        expect(result.es_total_count).to eq(100)
        expect(result.pagination_total_count).to eq(30)
        expect(result.records.total_pages).to eq(2)
        expect(result.records.next_page).to eq(2)
    end

    it "max_result_window末端の部分ページで復元不能分をpagination_total_countから差し引く" do
        client = double("client")
        records = (21..27).map { |id| article_model.new(id) }
        hits = (21..30).map do |id|
            {
                "_index"  => "test__articles__default__2026_07_03_03_10_00_123456",
                "_id"     => id.to_s,
                "_source" => {
                    AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                    AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME.to_s     => id.to_s,
                },
            }
        end
        response = {
            "hits" => {
                "hits"  => hits,
                "total" => { "value" => 100 },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
        expect(client)
            .to receive(:search) do |index:, body:|
                expect(index).to eq("test__articles__default")
                expect(body[:from]).to eq(20)
                expect(body[:size]).to eq(10)

                response
            end
        allow(article_model)
            .to receive(:where)
            .with(id: (21..30).map(&:to_s))
            .and_return(records)

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
            },
            page:     2,
            per_page: 20,
        )

        expect(result.records).to eq(records)
        expect(result.es_total_count).to eq(100)
        expect(result.total_count).to eq(97)
        expect(result.records.total_count).to eq(97)
        expect(result.pagination_total_count).to eq(27)
        expect(result.records.total_pages).to eq(2)
        expect(result.records.next_page).to eq(nil)
    end

    it "hitsが無い異常レスポンスはレコード関連結果を空にする" do
        client = double("client")
        response = {
            "hits" => {
                "total" => { "value" => 100 },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
        allow(client)
            .to receive(:search)
            .and_return(response)

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
            },
            page:     2,
            per_page: 20,
        )

        expect(result.records).to eq([])
        expect(result.records_with_hit).to eq([])
        expect(result.total_count).to eq(0)
        expect(result.records.total_count).to eq(0)
        expect(result.es_total_count).to eq(0)
        expect(result.raw_response).to equal(response)
    end

    it "1件でも_sourceが無い場合はページ内hitを復元不能として件数補正する" do
        client = double("client")
        response = {
            "hits" => {
                "hits" => [
                    {
                        "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                        "_id" => "1",
                        "_source" => {
                            AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                        },
                    },
                    {
                        "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                        "_id" => "2",
                    },
                ],
                "total" => { "value" => 100 },
            },
            "aggregations" => {
                "status" => {
                    "buckets" => [
                        { "key" => "published", "doc_count" => 10 },
                    ],
                },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
        allow(client)
            .to receive(:search)
            .and_return(response)
        expect(article_model).not_to receive(:where)

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
            },
            page:     1,
            per_page: 20,
        )

        expect(result.records).to eq([])
        expect(result.records_with_hit).to eq([])
        expect(result.total_count).to eq(98)
        expect(result.records.total_count).to eq(98)
        expect(result.es_total_count).to eq(100)
        expect(result.pagination_total_count).to eq(28)
        expect(result.aggs(:status)).to eq([["published", 10]])
        expect(result.raw_response).to equal(response)
    end

    it "raw_body検索はArray形式のbucketsを簡易結果へ変換しkeyがない場合はdoc_countだけを返す" do
        client = double("client")
        response = {
            "hits" => {
                "hits"  => [],
                "total" => { "value" => 0 },
            },
            "aggregations" => {
                "status" => {
                    "buckets" => [
                        { "key" => "published", "doc_count" => 10 },
                        { "key" => "draft", "doc_count" => 3 },
                    ],
                },
                "published" => {
                    "buckets" => [
                        { "key" => 1, "key_as_string" => "true", "doc_count" => 10 },
                        { "key" => 0, "key_as_string" => "false", "doc_count" => 3 },
                    ],
                },
                "formatted_date" => {
                    "buckets" => [
                        { "key" => 1_785_283_200_000, "key_as_string" => "2026-07", "doc_count" => 10 },
                        { "key" => 1_785_369_600_000, "key_as_string" => "2026-07", "doc_count" => 3 },
                    ],
                },
                "score_ranges" => {
                    "buckets" => [
                        { "key" => "*-1.0", "to" => 1.0, "doc_count" => 10 },
                        { "key" => "middle", "from" => 1.0, "to" => 2.0, "doc_count" => 3 },
                        { "key" => "2.0-*", "from" => 2.0, "doc_count" => 1 },
                    ],
                },
                "anonymous_filters" => {
                    "buckets" => [
                        { "doc_count" => 10 },
                        { "doc_count" => 3 },
                    ],
                },
                "keyed_status" => {
                    "buckets" => {
                        "published" => { "doc_count" => 10 },
                        "draft"     => { "doc_count" => 3 },
                    },
                },
                "avg_price" => {
                    "value" => 12.5,
                },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
        expect(client)
            .to receive(:search)
            .and_return(response)

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
                aggs: {
                    status: {
                        terms: {
                            field: :status,
                        },
                    },
                    published: {
                        terms: {
                            field: :published,
                        },
                    },
                    formatted_date: {
                        date_histogram: {
                            field:             :published_at,
                            calendar_interval: :day,
                            format:            "yyyy-MM",
                        },
                    },
                    score_ranges: {
                        range: {
                            field: :score,
                            ranges: [
                                { to: 1.0 },
                                { from: 1.0, to: 2.0, key: "middle" },
                                { from: 2.0 },
                            ],
                        },
                    },
                    anonymous_filters: {
                        filters: {
                            keyed: false,
                            filters: [
                                {
                                    term: {
                                        status: "published",
                                    },
                                },
                                {
                                    term: {
                                        status: "draft",
                                    },
                                },
                            ],
                        },
                    },
                    keyed_status: {
                        filters: {
                            filters: {
                                published: {
                                    term: {
                                        status: "published",
                                    },
                                },
                            },
                        },
                    },
                    avg_price: {
                        avg: {
                            field: :price,
                        },
                    },
                },
            },
            page:     1,
            per_page: 20,
        )

        expect(result.aggs(:status)).to eq(
            [
                ["published", 10],
                ["draft", 3],
            ],
        )
        expect(result.aggs(:published)).to eq(
            [
                ["true", 10],
                ["false", 3],
            ],
        )
        expect(result.aggs(:formatted_date)).to eq(
            [
                ["2026-07", 10],
                ["2026-07", 3],
            ],
        )
        expect(result.aggs(:score_ranges)).to eq(
            [
                ["*-1.0", 10],
                ["middle", 3],
                ["2.0-*", 1],
            ],
        )
        expect(result.aggs(:anonymous_filters)).to eq([10, 3])
        expect(result.aggs(:keyed_status)).to eq([])
        expect(result.aggs(:avg_price)).to eq([])
        expect(result.aggs).to eq(
            status: [
                ["published", 10],
                ["draft", 3],
            ],
            published: [
                [1, 10],
                [0, 3],
            ],
            formatted_date: [
                [1_785_283_200_000, 10],
                [1_785_369_600_000, 3],
            ],
            score_ranges: [
                ["*-1.0", 10],
                ["middle", 3],
                ["2.0-*", 1],
            ],
            anonymous_filters: [10, 3],
        )
        expect(result.raw_response).to equal(response)
    end

    it "raw_body検索は track_total_hits を自動指定せず明示値を保持する" do
        client = double("client")
        received_bodies = []

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
        allow(client)
            .to receive(:search) do |args|
                received_bodies << args[:body]

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    match_all: {},
                },
            },
        )
        AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                track_total_hits: true,
                query: {
                    match_all: {},
                },
            },
        )

        expect(received_bodies[0]).not_to have_key(:track_total_hits)
        expect(received_bodies[1][:track_total_hits]).to eq(true)
    end

    it "pageが不正ならparams_invalidの空結果を返し、per_pageが0なら既定値を使用する" do
        result = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:    [:title],
                },
            ],
            page:      "2",
            per_page:  20,
            dump_body: true,
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(result.records).to eq([])
        expect(result.records.page).to eq(1)
        expect(result.records.per_page).to eq(25)

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:    [:title],
                },
            ],
            page:      1,
            per_page:  0,
            dump_body: true,
        )

        expect(body[:from]).to eq(0)
        expect(body[:size]).to eq(25)
    end

    it "raw_bodyのnested keyを変更せずtop levelのfromとsizeだけを置き換える" do
        client = double("client")
        body = {
            "from" => 999,
            size: 999,
            "query" => {
                "term" => {
                    "status" => "published",
                },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:body].key?("from")).to eq(false)
                expect(args[:body].key?("size")).to eq(false)
                expect(args[:body][:from]).to eq(0)
                expect(args[:body][:size]).to eq(20)
                expect(args[:body]["query"]).to eq(
                    "term" => {
                        "status" => "published",
                    },
                )

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::Searcher.search(
            [article_index_target],
            raw_body: body,
            page:     1,
            per_page: 20,
        )

        expect(body).to eq(
            "from" => 999,
            size: 999,
            "query" => {
                "term" => {
                    "status" => "published",
                },
            },
        )
    end

    it "build_model_bool指定時にSymbol keyのquery.boolへモデル条件を追加する" do
        client = double("client")
        body = {
            query: {
                bool: {
                    must: [
                        { match_all: {} },
                    ],
                },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:body].dig(:query, :bool, :filter)).to eq([
                    {
                        terms: {
                            AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME =>
                                ["Article"],
                        },
                    },
                ])

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::Searcher.search(
            [article_index_target],
            raw_body:        body,
            build_model_bool: true,
        )

        expect(body).to eq(
            query: {
                bool: {
                    must: [
                        { match_all: {} },
                    ],
                },
            },
        )
    end

    it "既存のHash filterを保持して複数モデル条件を追加する" do
        client = double("client")
        body = {
            query: {
                bool: {
                    filter: {
                        term: {
                            status: "published",
                        },
                    },
                },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:index]).to eq(
                    "test__articles__default,test__documents__default",
                )
                expect(args[:body].dig(:query, :bool, :filter)).to eq([
                    {
                        term: {
                            status: "published",
                        },
                    },
                    {
                        terms: {
                            AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME =>
                                ["Article", "Document"],
                        },
                    },
                ])

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::Searcher.search(
            [article_index_target, document_index_target],
            raw_body:        body,
            build_model_bool: true,
        )
    end

    it "String keyと既存のArray filterを保持してモデル条件を追加する" do
        client = double("client")
        body = {
            "query" => {
                "bool" => {
                    "filter" => [
                        {
                            "term" => {
                                "status" => "published",
                            },
                        },
                    ],
                },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:body].dig("query", "bool", "filter")).to eq([
                    {
                        "term" => {
                            "status" => "published",
                        },
                    },
                    {
                        terms: {
                            AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME =>
                                ["Article"],
                        },
                    },
                ])
                expect(args[:body].dig("query", "bool")).not_to have_key(:filter)

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::Searcher.search(
            [article_index_target],
            raw_body:        body,
            build_model_bool: true,
        )
    end

    it "build_model_bool falseの場合はモデル条件を追加しない" do
        client = double("client")

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:body].dig(:query, :bool)).not_to have_key(:filter)

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                query: {
                    bool: {
                        must: [
                            { match_all: {} },
                        ],
                    },
                },
            },
            build_model_bool: false,
        )
    end

    it "build_model_boolの型とraw_body構造を検証する" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        expect(AreSearch).not_to receive(:client)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    query: {
                        bool: {},
                    },
                },
                build_model_bool: "true",
            )
        end.to raise_error(ArgumentError, /true または false/)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    query: {
                        match_all: {},
                    },
                },
                build_model_bool: true,
            )
        end.to raise_error(ArgumentError, /query.bool が必要/)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    query: {
                        bool: {
                            filter: "published",
                        },
                    },
                },
                build_model_bool: true,
            )
        end.to raise_error(ArgumentError, /query.bool.filter を Hash、Array、nil/)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    query: { bool: {} },
                    "query" => { "bool" => {} },
                },
                build_model_bool: true,
            )
        end.to raise_error(ArgumentError, /:query と "query" を同時に指定できません/)
    end
end
