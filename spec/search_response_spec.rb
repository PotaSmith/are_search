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

        allow(AreSearch::IndexManager)
            .to receive(:index_alias_exists?)
            .with("test__articles__default")
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
