# frozen_string_literal: true

require "spec_helper"

RSpec.describe "search option flow" do
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
                            status: { type: "keyword" },
                            count:  { type: "integer" },
                        },
                        runtime: {
                            runtime_title: { type: "text" },
                            runtime_score: { type: "double" },
                        },
                    },
                }
            end

            def initialize
                @id = 1
            end
        end
    end

    let(:article) do
        article_model.new
    end

    let(:article_index_target) do
        AreSearch::IndexTarget.new(article_model, :default)
    end

    before do
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test__articles__default")
            .and_return(true)
    end

    it "query_stringにStringとnilを受け付ける" do
        allow(AreSearch::Searcher)
            .to receive(:execute_and_build_result)
            .and_return(:search_result)

        string_result = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "Rails",
            fields:       [:title],
        )
        nil_result = AreSearch::Searcher.search(
            [article_index_target],
            query_string: nil,
            fields:       [:title],
        )

        expect(string_result).to eq(:search_result)
        expect(nil_result).to eq(:search_result)
    end

    it "nilと空文字列ではcombined_fields句を作らない" do
        nil_body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: nil,
            fields:       [:title],
            dump_body:    true,
        )
        empty_body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "",
            fields:       [:title],
            dump_body:    true,
        )

        expect(nil_body.dig(:query, :bool)).not_to have_key(:must)
        expect(empty_body.dig(:query, :bool)).not_to have_key(:must)
    end

    it "query_stringの非String値を拒否する" do
        [{}, [], 1, :query, true, false].each do |query_string|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    query_string: query_string,
                    fields:       [:title],
                )
            end.to raise_error(ArgumentError, /String/)
        end
    end

    it "未知のオプションを拒否する" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields:  [:title],
                unknown: true,
            )
        end.to raise_error(ArgumentError, /未知の検索オプション/)
    end

    it "検証済みのElasticsearch値を変更せずbodyへ渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "検索語",
            fields: {
                title: 2.5,
            },
            sort: {
                status: "desc",
            },
            aggs: [
                {
                    status: {
                        size: -1,
                    },
                },
            ],
            highlight: {
                fields: {
                    status: {
                        number_of_fragments: 0,
                    },
                },
                max_analyzed_offset: 0,
            },
            where: {
                count: {
                    range: {
                        gte: 0,
                    },
                },
            },
            where_not: {
                status: {
                    terms: ["deleted"],
                },
            },
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must, :combined_fields, :fields)).to eq([
            "title^2.5",
        ])
        expect(body.dig(:query, :bool, :filter)).to include(
            {
                range: {
                    count: {
                        gte: 0,
                    },
                },
            },
            {
                bool: {
                    should: [
                        {
                            term: {
                                status: "published",
                            },
                        },
                    ],
                    minimum_should_match: 1,
                },
            },
        )
        expect(body.dig(:query, :bool, :must_not)).to eq([
            {
                terms: {
                    status: ["deleted"],
                },
            },
        ])
        expect(body[:sort]).to eq(
            status: "desc",
        )
        expect(body.dig(:aggs, :status, :terms, :size)).to eq(-1)
        expect(body[:highlight]).to include(
            fields: {
                status: {
                    number_of_fragments: 0,
                },
            },
            max_analyzed_offset: 0,
        )
    end

    it "単純検索とMore Like This検索でwhere_orをfilter内のbool.shouldへ入れる" do
        simple_body = AreSearch::Searcher.search(
            [article_index_target],
            fields: [:title],
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )
        mlt_body = AreSearch::Searcher.search(
            [article_index_target],
            mlt_instance:     article,
            mlt_index_target: article_index_target,
            mlt_params: {
                fields: [:title, :status],
            },
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )

        [simple_body, mlt_body].each do |body|
            where_or_bool = body.dig(:query, :bool, :filter).find do |filter_clause|
                filter_clause.key?(:bool)
            end

            expect(where_or_bool).to eq(
                bool: {
                    should: [
                        {
                            term: {
                                status: "published",
                            },
                        },
                    ],
                    minimum_should_match: 1,
                },
            )
        end
    end

    it "where系オプションを持ち、shouldを未知のオプションとして扱う" do
        expect(AreSearch::Searcher::OPTION_DEFINITIONS.keys).to include(
            :where,
            :where_not,
            :where_or,
        )
        expect(AreSearch::Searcher::OPTION_DEFINITIONS.keys).not_to include(:should)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields: [:title],
                should: [],
            )
        end.to raise_error(ArgumentError, /未知の検索オプション/)
    end

    it "MLT固有パラメーターはmlt_params配下だけで受け付ける" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt_instance:          article,
                mlt_index_target:      article_index_target,
                mlt_params: {
                    fields: [:title, :status],
                },
                minimum_should_match:  "50%",
                dump_body:             true,
            )
        end.to raise_error(ArgumentError, /未知の検索オプション/)

        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt_instance:     article,
            mlt_index_target: article_index_target,
            mlt_params: {
                fields:               [:title, :status],
                minimum_should_match: "50%",
            },
            dump_body: true,
        )

        expect(
            body.dig(:query, :bool, :must, :more_like_this, :minimum_should_match),
        ).to eq("50%")
    end

    it "runtimeのtextフィールドを検索対象にできる" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "検索語",
            fields:       [:runtime_title],
            dump_body:    true,
        )

        expect(body.dig(:query, :bool, :must, :combined_fields, :fields)).to eq([
            "runtime_title",
        ])

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                query_string: "検索語",
                fields:       [:runtime_score],
                dump_body:    true,
            )
        end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)
    end

    it "mappingsに無いフィールドを表記に関係なく拒否する" do
        search_fields = [
            :"title.keyword",
            :Title,
            :"title*",
        ]

        search_fields.each do |field_name|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    query_string: "検索語",
                    fields:       [field_name],
                    dump_body:    true,
                )
            end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)
        end

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                where: {
                    :"OtherModel.secret" => {
                        term: "value",
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /any_non_text_without_text_fields/)
    end

    it "More Like Thisはmlt_paramsをmore_like_this句へ渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt_instance:     article,
            mlt_index_target: article_index_target,
            mlt_params: {
                fields:               [:title, :status],
                min_term_freq:        0,
                min_doc_freq:         -1,
                max_query_terms:      0,
                min_word_length:      0,
                minimum_should_match: "ESで判定する値",
                boost_terms:          1,
                max_word_length:       30,
                include:               true,
            },
            dump_body: true,
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt[:fields]).to eq(["title", "status"])
        expect(mlt[:min_term_freq]).to eq(0)
        expect(mlt[:min_doc_freq]).to eq(-1)
        expect(mlt[:max_query_terms]).to eq(0)
        expect(mlt[:min_word_length]).to eq(0)
        expect(mlt[:minimum_should_match]).to eq("ESで判定する値")
        expect(mlt[:boost_terms]).to eq(1)
        expect(mlt[:max_word_length]).to eq(30)
        expect(mlt[:include]).to eq(true)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt_instance:     article,
                mlt_index_target: article_index_target,
                mlt_params: {
                    fields: [:count],
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /any_text_or_keyword_without_other_type_fields/)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt_instance:     article,
                mlt_index_target: article_index_target,
                mlt_params: {
                    fields: [:title],
                    like:   "other document",
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /指定できないキー.*like/)
    end

    it "mlt_paramsの省略値をMore Like This句へ設定する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt_instance:     article,
            mlt_index_target: article_index_target,
            mlt_params: {
                fields: [:title],
            },
            dump_body: true,
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt[:min_term_freq]).to eq(2)
        expect(mlt[:min_doc_freq]).to eq(5)
        expect(mlt[:max_query_terms]).to eq(25)
        expect(mlt).not_to have_key(:minimum_should_match)
        expect(mlt).not_to have_key(:boost_terms)
    end

    it "where_orとMLTのminimum_should_matchを別階層へ出力する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt_instance:     article,
            mlt_index_target: article_index_target,
            mlt_params: {
                fields:               [:title],
                minimum_should_match: "50%",
            },
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )

        where_or_bool = body.dig(:query, :bool, :filter).find do |filter_clause|
            filter_clause.key?(:bool)
        end

        expect(where_or_bool.dig(:bool, :minimum_should_match)).to eq(1)
        expect(
            body.dig(:query, :bool, :must, :more_like_this, :minimum_should_match),
        ).to eq("50%")
    end

    it "複数モデル用のARオプションはHash構造を必要とする" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                fields: [:title],
                model_results_where: [],
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /Hash/)
    end
end
