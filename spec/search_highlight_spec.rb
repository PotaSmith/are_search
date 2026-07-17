# frozen_string_literal: true

require "spec_helper"

RSpec.describe "search highlight" do
    let(:article_model) do
        Class.new do
            attr_reader :id

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

            def self.are_search_es_mappings
                {
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title:  { type: "text" },
                            body:   { type: "text" },
                            status: { type: "keyword" },
                            count:  { type: "integer" },
                        },
                    },
                }
            end

            def initialize
                @id = 1
            end
        end
    end

    let(:document_model) do
        Class.new do
            def self.name
                "Document"
            end

            def self.are_search_ar_table_name
                "documents"
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            def self.are_search_es_mappings
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

    let(:article) do
        article_model.new
    end

    let(:article_index_target) do
        AreSearch::IndexTarget.new(article_model, :default)
    end

    let(:document_index_target) do
        AreSearch::IndexTarget.new(document_model, :default)
    end

    before do
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test__articles__default")
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test__documents__default")
            .and_return(true)
    end

    it "highlight未指定時はhighlight bodyを作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            fields:    [:title, :body],
            dump_body: true,
        )

        expect(body).not_to have_key(:highlight)
    end

    it "highlightにはfieldsを必須とする" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields: [:title, :body],
                highlight: {
                    fragment_size: 150,
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /必要なキー.*fields/)
    end

    it "fieldsのArray形式を空オプションのHashへ変換する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            fields: [:title, :body],
            highlight: {
                fields: [:title, :body],
                type: "unified",
                require_field_match: false,
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            type: "unified",
            require_field_match: false,
            fields: {
                title: {},
                body:  {},
            },
        )
    end

    it "fieldsのHash形式はフィールド別オプションを保持する" do
        body = AreSearch::Searcher.search(
            [article_index_target, document_index_target],
            fields: [:title, :body],
            highlight: {
                fields: {
                    body: {
                        fragment_size: 150,
                        number_of_fragments: 3,
                    },
                    status: {
                        number_of_fragments: 0,
                    },
                },
                max_analyzed_offset: 1_000_000,
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            max_analyzed_offset: 1_000_000,
            fields: {
                body: {
                    fragment_size: 150,
                    number_of_fragments: 3,
                },
                status: {
                    number_of_fragments: 0,
                },
            },
        )
    end

    it "fieldsのHash形式では空のフィールドオプションを受け付けない" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields: [:title],
                highlight: {
                    fields: {
                        title: {},
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError)
    end

    it "textまたはkeyword以外のフィールドをhighlight対象にできない" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields: [:title],
                highlight: {
                    fields: {
                        count: {
                            number_of_fragments: 0,
                        },
                    },
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /opts\[:highlight\]\[fields\] に未知のキーがあります: count/,
        )
    end

    it "More Like This検索でも同じhighlight定義を使用する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt_instance:     article,
            mlt_index_target: article_index_target,
            mlt_params: {
                fields: [:title, :status],
            },
            highlight: {
                fields: [:body, :status],
                fragment_size: 150,
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fragment_size: 150,
            fields: {
                body:   {},
                status: {},
            },
        )
    end
    it "pre_tags・post_tags・encoderをそのまま渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "Rails",
            fields:       [:title],
            highlight: {
                fields:    [:title],
                pre_tags:  ["<mark>"],
                post_tags: ["</mark>"],
                encoder:   "default",
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fields: {
                title: {},
            },
            pre_tags:  ["<mark>"],
            post_tags: ["</mark>"],
            encoder:   "default",
        )
    end

end
