# frozen_string_literal: true

require "spec_helper"

RSpec.describe "search response" do
    let(:article_model) do
        Class.new do
            def self.name
                "Article"
            end

            def self.are_search_ar_table_name
                "articles"
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            def self.are_search_index_mappings
                {
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        _source: {
                            includes: [
                                :title,
                                :payload,
                            ],
                        },
                        properties: {
                            title:   { type: "text" },
                            payload: { type: "object", enabled: false },
                        },
                    },
                }
            end
        end
    end

    let(:article_index_target) do
        AreSearch::IndexTarget.new(article_model, :default)
    end

    before do
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")

        allow(AreSearch::EsAdapter)
            .to receive(:index_alias_exists?)
            .with(index_alias_name: "test__articles__default")
            .and_return(true)
    end

    it "response未指定時は復元用予約フィールドだけを_sourceへ指定する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            dump_body: true,
        )

        expect(body[:_source]).to eq([
            "are_search_reserved_ar_model_class_name",
            "are_search_reserved_ar_instance_key",
        ])
    end

    it "response.sourceを復元用予約フィールドへ追加する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                source: [
                    "title",
                    "payload.display.*",
                ],
            },
            dump_body: true,
        )

        expect(body[:_source]).to eq([
            "are_search_reserved_ar_model_class_name",
            "are_search_reserved_ar_instance_key",
            "title",
            "payload.display.*",
        ])
    end

    it "response.sourceはmappingと照合せずsource pathを維持する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                source: [
                    "unknown.field",
                    "*.display_name",
                ],
            },
            dump_body: true,
        )

        expect(body[:_source]).to include(
            "unknown.field",
            "*.display_name",
        )
    end

    it "response.sourceに予約フィールドを指定しても重複させない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                source: [
                    "are_search_reserved_ar_instance_key",
                    "title",
                    "title",
                ],
            },
            dump_body: true,
        )

        expect(body[:_source]).to eq([
            "are_search_reserved_ar_model_class_name",
            "are_search_reserved_ar_instance_key",
            "title",
        ])
    end

    it "response.sourceはStringのArrayに限定する" do
        invalid_values = [
            [],
            :title,
            [:title],
            "title",
            nil,
        ]

        invalid_values.each do |invalid_value|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "Rails",
                            fields:       [:title],
                        },
                    ],
                    response: {
                        source: invalid_value,
                    },
                    dump_body: true,
                )
            end.to raise_error(ArgumentError, /opts\[:response\]\[source\]/)
        end
    end

    it "単一targetのショートハンドでもresponse.sourceを使用できる" do
        body = article_index_target.are_search_search(
            "Rails",
            fields: [:title],
            response: {
                source: ["title"],
            },
            dump_body: true,
        )

        expect(body[:_source]).to eq([
            "are_search_reserved_ar_model_class_name",
            "are_search_reserved_ar_instance_key",
            "title",
        ])
    end

    it "response.fieldsをElasticsearchのfieldsへ指定する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                fields: [
                    "runtime_status",
                    "payload.display.*",
                ],
            },
            dump_body: true,
        )

        expect(body[:fields]).to eq([
            "runtime_status",
            "payload.display.*",
        ])
    end

    it "response.fieldsはmappingと照合せずfield patternを維持する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                fields: [
                    "unknown.field",
                    "*.display_name",
                ],
            },
            dump_body: true,
        )

        expect(body[:fields]).to eq([
            "unknown.field",
            "*.display_name",
        ])
    end

    it "response.fieldsはStringのArrayに限定する" do
        invalid_values = [
            [],
            :title,
            [:title],
            "title",
            nil,
        ]

        invalid_values.each do |invalid_value|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "Rails",
                            fields:       [:title],
                        },
                    ],
                    response: {
                        fields: invalid_value,
                    },
                    dump_body: true,
                )
            end.to raise_error(ArgumentError, /opts\[:response\]\[fields\]/)
        end
    end

    it "response.stored_fieldsをElasticsearchのstored_fieldsへ指定する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                stored_fields: [
                    "body",
                    "payload.raw",
                ],
            },
            dump_body: true,
        )

        expect(body[:stored_fields]).to eq([
            "body",
            "payload.raw",
        ])
    end

    it "response.stored_fieldsはStringのArrayに限定する" do
        invalid_values = [
            [],
            :body,
            [:body],
            "body",
            nil,
        ]

        invalid_values.each do |invalid_value|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "Rails",
                            fields:       [:title],
                        },
                    ],
                    response: {
                        stored_fields: invalid_value,
                    },
                    dump_body: true,
                )
            end.to raise_error(
                ArgumentError,
                /opts\[:response\]\[stored_fields\]/,
            )
        end
    end

    it "response.docvalue_fieldsをElasticsearchのdocvalue_fieldsへ指定する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            response: {
                docvalue_fields: [
                    "status",
                    "published_at",
                ],
            },
            dump_body: true,
        )

        expect(body[:docvalue_fields]).to eq([
            "status",
            "published_at",
        ])
    end

    it "response.docvalue_fieldsはStringのArrayに限定する" do
        invalid_values = [
            [],
            :status,
            [:status],
            "status",
            nil,
        ]

        invalid_values.each do |invalid_value|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "Rails",
                            fields:       [:title],
                        },
                    ],
                    response: {
                        docvalue_fields: invalid_value,
                    },
                    dump_body: true,
                )
            end.to raise_error(
                ArgumentError,
                /opts\[:response\]\[docvalue_fields\]/,
            )
        end
    end

    it "raw_bodyとは同時に指定できない" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    query: {
                        match_all: {},
                    },
                },
                response: {
                    source: ["title"],
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /検索パラメータが不正な組み合わせ/)
    end
end

RSpec.describe "search runtime mappings" do
    let(:article_model) do
        Class.new do
            def self.name
                "Article"
            end

            def self.are_search_ar_table_name
                "articles"
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            def self.are_search_index_mappings
                {
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title:  { type: "text" },
                            body:   { type: "text" },
                            status: { type: "keyword" },
                        },
                    },
                }
            end
        end
    end

    let(:article_index_target) do
        AreSearch::IndexTarget.new(article_model, :default)
    end

    let(:runtime_mappings) do
        {
            :"runtime.score" => {
                type: :double,
                script: {
                    "source" => "emit(1.0)",
                },
            },
        }
    end

    before do
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")

        allow(AreSearch::EsAdapter)
            .to receive(:index_alias_exists?)
            .with(index_alias_name: "test__articles__default")
            .and_return(true)
    end

    it "標準検索のruntime_mappingsをwhere・sort・aggsで使用する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            runtime_mappings: runtime_mappings,
            enable_runtime_mappings: true,
            where: {
                :"runtime.score" => {
                    range: {
                        gte: 0,
                    },
                },
            },
            sort: {
                :"runtime.score" => :desc,
            },
            aggs: [:"runtime.score"],
            dump_body: true,
        )

        expect(body[:runtime_mappings]).to eq(runtime_mappings)
        expect(body.dig(:query, :bool, :filter)).to include(
            {
                range: {
                    :"runtime.score" => {
                        gte: 0,
                    },
                },
            },
        )
        expect(body[:sort]).to eq([
            {
                :"runtime.score" => :desc,
            },
        ])
        expect(body.dig(:aggs, :"runtime.score", :terms, :field)).to eq(:"runtime.score")
    end

    it "runtime fieldと同名のpropertiesがある場合はruntime fieldを優先する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:body],
                },
            ],
            runtime_mappings: {
                title: {
                    type: "keyword",
                    script: {
                        source: "emit('runtime')",
                    },
                },
            },
            enable_runtime_mappings: true,
            where: {
                title: {
                    term: "runtime",
                },
            },
            sort: {
                title: :asc,
            },
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :filter)).to include(
            {
                term: {
                    title: "runtime",
                },
            },
        )
        expect(body[:sort]).to eq([
            {
                title: :asc,
            },
        ])
    end

    it "runtime_mappingsはtypeを持つSymbol keyのHashに限定する" do
        invalid_values = [
            [],
            {},
            {
                "runtime_score" => {
                    type: "double",
                },
            },
            {
                runtime_score: nil,
            },
            {
                runtime_score: {},
            },
            {
                runtime_score: {
                    "type" => "double",
                },
            },
            {
                runtime_score: {
                    type: 1,
                },
            },
            {
                runtime_score: {
                    type: "double",
                    "script" => {
                        source: "emit(1.0)",
                    },
                },
            },
        ]

        invalid_values.each do |invalid_value|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "Rails",
                            fields:       [:title],
                        },
                    ],
                    runtime_mappings: invalid_value,
                    enable_runtime_mappings: true,
                    dump_body: true,
                )
            end.to raise_error(ArgumentError, /runtime_mappings/)
        end
    end

    it "runtime fieldをtypeに応じてpropertiesと同じフィールド分類へ追加する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:runtime_title],
                },
            ],
            runtime_mappings: {
                runtime_title: {
                    type: :text,
                },
                runtime_status: {
                    type: "keyword",
                },
                runtime_score: {
                    type: "double",
                },
            },
            enable_runtime_mappings: true,
            where: {
                runtime_status: {
                    term: "published",
                },
                runtime_score: {
                    range: {
                        gte: 0,
                    },
                },
            },
            sort: {
                runtime_score: :desc,
            },
            aggs: [:runtime_status],
            highlight: {
                fields: [
                    :runtime_title,
                    :runtime_status,
                ],
            },
            dump_body: true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :combined_fields, :fields),
        ).to eq(["runtime_title"])
        expect(body.dig(:query, :bool, :filter)).to include(
            {
                term: {
                    runtime_status: "published",
                },
            },
            {
                range: {
                    runtime_score: {
                        gte: 0,
                    },
                },
            },
        )
        expect(body[:sort]).to eq([
            {
                runtime_score: :desc,
            },
        ])
        expect(body.dig(:aggs, :runtime_status, :terms, :field)).to eq(:runtime_status)
        expect(body.dig(:highlight, :fields)).to eq(
            runtime_title: {},
            runtime_status: {},
        )
    end

    it "標準検索のruntime_mappingsはenable_runtime_mappingsを必須にする" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: "Rails",
                        fields:       [:title],
                    },
                ],
                runtime_mappings: runtime_mappings,
            )
        end.to raise_error(
            ArgumentError,
            /enable_runtime_mappings: true/,
        )
    end

    it "raw_body内のruntime_mappingsもenable_runtime_mappingsを必須にする" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    runtime_mappings: runtime_mappings,
                    query: {
                        match_all: {},
                    },
                },
            )
        end.to raise_error(
            ArgumentError,
            /enable_runtime_mappings: true/,
        )
    end

    it "dump_bodyはenable_runtime_mappingsなしでもruntime_mappingsを返す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            runtime_mappings: runtime_mappings,
            dump_body: true,
        )

        expect(body[:runtime_mappings]).to eq(runtime_mappings)
    end

    it "raw_body内のruntime_mappingsを有効化してそのままbodyへ残す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                "runtime_mappings" => runtime_mappings,
                "query" => {
                    "match_all" => {},
                },
            },
            enable_runtime_mappings: true,
            dump_body: true,
        )

        expect(body["runtime_mappings"]).to eq(runtime_mappings)
    end

    it "raw_bodyとトップレベルruntime_mappingsは同時に使用できない" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                raw_body: {
                    query: {
                        match_all: {},
                    },
                },
                runtime_mappings: runtime_mappings,
                enable_runtime_mappings: true,
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /検索パラメータが不正な組み合わせ/)
    end

    it "標準検索はruntime_mappingsをbody policyから除外して元bodyを送信する" do
        client = double("client")
        response = {
            "hits" => {
                "hits" => [],
                "total" => {
                    "value" => 0,
                },
            },
        }

        expect(AreSearch.search_body_policy)
            .to receive(:valid?) do |body_for_policy|
                expect(body_for_policy).not_to have_key(:runtime_mappings)

                true
            end

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |index:, body:|
                expect(index).to eq("test__articles__default")
                expect(body[:runtime_mappings]).to eq(runtime_mappings)

                response
            end

        AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            runtime_mappings: runtime_mappings,
            enable_runtime_mappings: true,
        )
    end

    it "raw_bodyもruntime_mappingsだけをbody policyから除外する" do
        client = double("client")
        response = {
            "hits" => {
                "hits" => [],
                "total" => {
                    "value" => 0,
                },
            },
        }

        expect(AreSearch.search_body_policy)
            .to receive(:valid?) do |body_for_policy|
                expect(body_for_policy).not_to have_key("runtime_mappings")
                expect(body_for_policy["query"]).to eq(
                    "match_all" => {},
                )

                true
            end

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)

        expect(client)
            .to receive(:search) do |index:, body:|
                expect(index).to eq("test__articles__default")
                expect(body["runtime_mappings"]).to eq(runtime_mappings)

                response
            end

        AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {
                "runtime_mappings" => runtime_mappings,
                "query" => {
                    "match_all" => {},
                },
            },
            enable_runtime_mappings: true,
        )
    end
end
