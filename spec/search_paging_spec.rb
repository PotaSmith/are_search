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
        class_double("Article", name: "Article")
    end
    let(:document_model) do
        class_double("Document", name: "Document")
    end
    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                    article_model,
            target_name:                    :default,
            are_search_es_index_name:       "test_articles_default",
            are_search_es_mappings:         article_mappings,
            are_search_es_index_settings:   article_index_settings,
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                    document_model,
            target_name:                    :default,
            are_search_es_index_name:       "test_documents_default",
            are_search_es_mappings:         document_mappings,
            are_search_es_index_settings:   document_index_settings,
        )
    end
    let(:article_index_settings) do
        { max_result_window: 30 }
    end
    let(:document_index_settings) do
        { max_result_window: 50 }
    end

    before do
        allow(article_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(document_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test_articles_default")
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test_documents_default")
            .and_return(true)
    end

    it "単一 target の MultiSearch は max_result_window を超える最後のページの size を縮める" do
        body = AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields:   [:title],
            page:     2,
            per_page: 20,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "MultiSearch は対象 index target の最小 max_result_window で size を縮める" do
        body = AreSearch::MultiSearch.search(
            [article_index_target, document_index_target],
            AreSearch::DumpBody,
            fields:   [:title],
            page:     2,
            per_page: 20,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "MoreLikeThis は max_result_window を超える最後のページの size を縮める" do
        body = AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields:   [:title],
            page:     2,
            per_page: 20,
        )

        expect(body[:track_total_hits]).to eq(true)
        expect(body[:from]).to eq(20)
        expect(body[:size]).to eq(10)
    end

    it "RawSearch も max_result_window 補正を行う" do
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
                expect(args[:index]).to eq("test_articles_default")
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

        result = AreSearch::RawSearch.search(
            [article_index_target],
            body,
            page:     3,
            per_page: 20,
        )

        expect(result.records.total_count).to eq(100)
        expect(result.records.es_total_count).to eq(100)
    end

    it "DB 復元で落ちた hit の件数を total_count から差し引き、ES の件数は es_total_count に残す" do
        client = double("client")
        body = {
            query: {
                match_all: {},
            },
        }
        record = double("record", id: 1)
        response = {
            "hits" => {
                "hits"  => [
                    {
                        "_index"  => "test_articles_default",
                        "_id"     => "1",
                        "_source" => {
                            AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                            AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s     => "1",
                        },
                    },
                    {
                        "_index"  => "test_articles_default",
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
                "test_articles_default/#{id}"
            end

        allow(article_model)
            .to receive(:where)
            .with(id: ["1", "2"])
            .and_return([record])

        result = AreSearch::RawSearch.search(
            [article_index_target],
            body,
            page:     1,
            per_page: 20,
        )

        expect(result.records).to eq([record])
        expect(result.records_with_target_names).to eq([[record, :default]])
        expect(result.records.total_count).to eq(99)
        expect(result.records.es_total_count).to eq(100)
    end

    it "RawSearch は buckets を持つ aggs だけ result.aggs に変換し raw_response で生レスポンスを返す" do
        client = double("client")
        body = {
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
        }
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

        result = AreSearch::RawSearch.search(
            [article_index_target],
            body,
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
        expect(result.raw_response["aggregations"]["avg_price"]["value"]).to eq(12.5)
    end

    it "RawSearch は track_total_hits true を自動指定しない" do
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
                expect(args[:body].key?(:track_total_hits)).to eq(false)

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 100 },
                    },
                }
            end

        AreSearch::RawSearch.search(
            [article_index_target],
            body,
            page:     1,
            per_page: 20,
        )
    end

    it "RawSearch は body に明示された track_total_hits true を保持する" do
        client = double("client")
        body = {
            track_total_hits: true,
            query: {
                match_all: {},
            },
        }

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |args|
                expect(args[:body][:track_total_hits]).to eq(true)

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 100 },
                    },
                }
            end

        AreSearch::RawSearch.search(
            [article_index_target],
            body,
            page:     1,
            per_page: 20,
        )
    end
    it "page / per_page は正の整数だけを許可する" do
        expect do
            AreSearch::MultiSearch.search(
                [article_index_target],
                AreSearch::DumpBody,
                fields:   [:title],
                page:     "2",
                per_page: 20,
            )
        end.to raise_error(ArgumentError, /:page は正の整数/)

        expect do
            AreSearch::MultiSearch.search(
                [article_index_target],
                AreSearch::DumpBody,
                fields:   [:title],
                page:     1,
                per_page: 0,
            )
        end.to raise_error(ArgumentError, /:per_page は正の整数/)
    end

    it "RawSearch は body の nested key を変更せず top level の from / size だけを置き換える" do
        client = double("client")
        body = {
            "from" => 999,
            :size => 999,
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

        AreSearch::RawSearch.search(
            [article_index_target],
            body,
            page:     1,
            per_page: 20,
        )

        expect(body).to eq(
            "from" => 999,
            :size => 999,
            "query" => {
                "term" => {
                    "status" => "published",
                },
            },
        )
    end


    it "RawSearch は build_model_bool 指定時に Symbol key の query.bool へモデル条件を追加する" do
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

        AreSearch::RawSearch.search(
            [article_index_target],
            body,
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

    it "RawSearch は既存の Hash filter を保持して複数モデル条件を追加する" do
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
                    "test_articles_default,test_documents_default",
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

        AreSearch::RawSearch.search(
            [article_index_target, document_index_target],
            body,
            build_model_bool: true,
        )

        expect(body).to eq(
            query: {
                bool: {
                    filter: {
                        term: {
                            status: "published",
                        },
                    },
                },
            },
        )
    end

    it "RawSearch は String key と既存の Array filter を保持してモデル条件を追加する" do
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

        AreSearch::RawSearch.search(
            [article_index_target],
            body,
            build_model_bool: true,
        )

        expect(body).to eq(
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
        )
    end

    it "RawSearch は build_model_bool false の場合にモデル条件を追加しない" do
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
                expect(args[:body].dig(:query, :bool)).not_to have_key(:filter)

                {
                    "hits" => {
                        "hits"  => [],
                        "total" => { "value" => 0 },
                    },
                }
            end

        AreSearch::RawSearch.search(
            [article_index_target],
            body,
            build_model_bool: false,
        )
    end

    it "RawSearch は build_model_bool に Boolean 以外を受け付けない" do
        expect(AreSearch).not_to receive(:client)

        expect do
            AreSearch::RawSearch.search(
                [article_index_target],
                { query: { bool: {} } },
                build_model_bool: "true",
            )
        end.to raise_error(
            ArgumentError,
            /build_model_bool は true または false/,
        )
    end

    it "RawSearch は build_model_bool 指定時に query.bool 以外を受け付けない" do
        expect(AreSearch).not_to receive(:client)

        expect do
            AreSearch::RawSearch.search(
                [article_index_target],
                { query: { match_all: {} } },
                build_model_bool: true,
            )
        end.to raise_error(
            ArgumentError,
            /query.bool が必要/,
        )
    end

    it "RawSearch は build_model_bool 指定時に filter の構造を確認する" do
        expect(AreSearch).not_to receive(:client)

        expect do
            AreSearch::RawSearch.search(
                [article_index_target],
                {
                    query: {
                        bool: {
                            filter: "published",
                        },
                    },
                },
                build_model_bool: true,
            )
        end.to raise_error(
            ArgumentError,
            /query.bool.filter を Hash、Array、nil/,
        )
    end

    it "RawSearch は build_model_bool 指定時に Symbol と String の同名 key を拒否する" do
        expect(AreSearch).not_to receive(:client)

        expect do
            AreSearch::RawSearch.search(
                [article_index_target],
                {
                    query: { bool: {} },
                    "query" => { "bool" => {} },
                },
                build_model_bool: true,
            )
        end.to raise_error(
            ArgumentError,
            /:query と "query" を同時に指定できません/,
        )
    end

end
