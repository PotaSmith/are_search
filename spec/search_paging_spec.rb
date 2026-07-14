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

            def self.are_search_es_mappings
                {
                    default: {
                        index_settings: {
                            max_result_window: 30,
                        },
                        properties: {
                            title: { type: "text" },
                        },
                    },
                }
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
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
            model_class:                  article_model,
            target_name:                  :default,
            are_search_es_index_name:     "test__articles__default",
            are_search_es_mappings:       article_mappings,
            are_search_es_index_settings: article_index_settings,
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                  document_model,
            target_name:                  :default,
            are_search_es_index_name:     "test__documents__default",
            are_search_es_mappings:       document_mappings,
            are_search_es_index_settings: document_index_settings,
        )
    end
    let(:article_index_settings) do
        { max_result_window: 30 }
    end
    let(:document_index_settings) do
        { max_result_window: 50 }
    end

    before do
        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test__articles__default")
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test__documents__default")
            .and_return(true)
    end

    it "単一 target は max_result_window を超える最後のページの size を縮める" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            fields:    [:title],
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
            fields:    [:title],
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
            mlt_instance:     article,
            mlt_index_target: mlt_index_target,
            mlt_params: {
                fields: [:title],
            },
            page:             2,
            per_page:         20,
            dump_body:        true,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "raw_body検索も max_result_window 補正を行う" do
        client = double("client")
        body = {
            query: {
                match_all: {},
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:index]).to eq("test__articles__default")
                expect(args[:body][:from]).to eq(30)
                expect(args[:body][:size]).to eq(0)
                expect(args[:body][:query]).to eq(match_all: {})

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 100 },
                    },
                }
            end

        result = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: body,
            page:     3,
            per_page: 20,
        )

        expect(result.records.total_count).to eq(100)
        expect(result.records.es_total_count).to eq(100)
    end

    it "DB復元で落ちたhitをtotal_countから差し引き、ES件数はes_total_countへ残す" do
        client = double("client")
        record = article_model.new(1)
        response = {
            "hits" => {
                "hits" => [
                    {
                        "_index"  => "test__articles__default",
                        "_id"     => "1",
                        "_source" => {
                            AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                            AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s     => "1",
                        },
                    },
                    {
                        "_index"  => "test__articles__default",
                        "_id"     => "2",
                        "_source" => {
                            AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                            AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s     => "2",
                        },
                    },
                ],
                "total" => { "value" => 100 },
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
        allow(client)
            .to receive(:search)
            .and_return(response)
        allow(article_index_target)
            .to receive(:are_search_es_composite_key) do |id|
                "test__articles__default/#{id}"
            end
        allow(article_model)
            .to receive(:where)
            .with(id: ["1", "2"])
            .and_return([record])

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

        expect(result.records).to eq([record])
        expect(result.records_with_target_names).to eq([[record, :default]])
        expect(result.records.total_count).to eq(99)
        expect(result.records.es_total_count).to eq(100)
    end

    it "raw_body検索はbucketsを持つaggsだけ変換しraw_responseで生レスポンスを返す" do
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

        expect(result.aggs).to eq(
            "status" => {
                "published" => 10,
                "draft"     => 3,
            },
        )
        expect(result.aggs.key?("avg_price")).to eq(false)
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

    it "pageとper_pageは正の整数だけを許可する" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields:    [:title],
                page:      "2",
                per_page:  20,
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /正の整数/)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields:    [:title],
                page:      1,
                per_page:  0,
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /正の整数/)
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
                            AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME =>
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
                            AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME =>
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
                            AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME =>
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
