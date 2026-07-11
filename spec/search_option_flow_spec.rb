# frozen_string_literal: true

require "spec_helper"

RSpec.describe "search option flow" do
    let(:article_mappings) do
        {
            properties: {
                title:  { type: "text" },
                status: { type: "keyword" },
                count:  { type: "integer" },
            },
            runtime: {
                runtime_score: { type: "double" },
            },
        }
    end
    let(:article_model) do
        class_double("Article", name: "Article")
    end
    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                  article_model,
            target_name:                  :default,
            are_search_es_index_name:     "test_articles_default",
            are_search_es_mappings:       article_mappings,
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end

    before do
        allow(article_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test_articles_default")
            .and_return(true)
    end


    it "MultiSearch は query に String、nil、DumpBody を受け付ける" do
        allow(AreSearch::MultiSearch)
            .to receive(:execute_and_build_result)
            .and_return(:search_result)

        string_result = AreSearch::MultiSearch.search(
            [article_index_target],
            "Rails",
            fields: [:title],
        )
        nil_result = AreSearch::MultiSearch.search(
            [article_index_target],
            nil,
            fields: [:title],
        )
        dump_body = AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields: [:title],
        )

        expect(string_result).to eq(:search_result)
        expect(nil_result).to eq(:search_result)
        expect(dump_body).to be_instance_of(Hash)
    end

    it "MultiSearch は nil と空文字列の query では combined_fields 句を作らない" do
        bodies = []

        allow(AreSearch::MultiSearch)
            .to receive(:execute_and_build_result) do |_search_index, body, _result_context|
                bodies << body

                :search_result
            end

        AreSearch::MultiSearch.search(
            [article_index_target],
            nil,
            fields: [:title],
        )
        AreSearch::MultiSearch.search(
            [article_index_target],
            "",
            fields: [:title],
        )

        expect(bodies.size).to eq(2)
        expect(bodies[0].dig(:query, :bool)).not_to have_key(:must)
        expect(bodies[1].dig(:query, :bool)).not_to have_key(:must)
    end

    it "MultiSearch は query の非文字列値を拒否する" do
        invalid_queries = [
            {},
            [],
            1,
            :query,
            true,
            false,
        ]

        invalid_queries.each do |query|
            expect do
                AreSearch::MultiSearch.search(
                    [article_index_target],
                    query,
                    fields: [:title],
                )
            end.to raise_error(
                ArgumentError,
                /multi_search query は String または nil/,
            )
        end
    end

    it "MultiSearch は query の型より未知オプションを先に確認する" do
        expect do
            AreSearch::MultiSearch.search(
                [article_index_target],
                {},
                fields:  [:title],
                unknown: true,
            )
        end.to raise_error(ArgumentError, /未知のオプション.*unknown/)
    end

    it "単一 target の MultiSearch は検証後に ES 固有値を変更せず body へ渡す" do
        body = AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields: {
                status: "ESで判定するboost",
            },
            sort: "status",
            aggs: [
                {
                    status: {
                        size: -1,
                    },
                },
            ],
            highlight: {
                fields: [:status],
                max_analyzed_offset: 0,
            },
            where: {
                count: { gte: 0 },
            },
            where_not: [
                {
                    field: :status,
                    value: ["deleted"],
                    boost: "ESで判定するboost",
                },
            ],
            where_or: [
                {
                    field: :status,
                    value: "published",
                    boost: "ESで判定するboost",
                },
            ],
        )

        expect(body.dig(:query, :bool, :must, :combined_fields, :fields)).to eq([
            "status^ESで判定するboost",
        ])
        expect(body.dig(:query, :bool, :minimum_should_match)).to eq(1)
        expect(body.dig(:query, :bool, :filter)).to include(
            {
                range: {
                    count: {
                        gte: 0,
                    },
                },
            },
        )
        expect(body.dig(:query, :bool, :must_not)).to eq([
            {
                terms: {
                    status: ["deleted"],
                    boost: "ESで判定するboost",
                },
            },
        ])
        expect(body.dig(:query, :bool, :should)).to eq([
            {
                term: {
                    status: {
                        value: "published",
                        boost: "ESで判定するboost",
                    },
                },
            },
        ])
        expect(body[:sort]).to eq("status")
        expect(body.dig(:aggs, :status, :terms, :size)).to eq(-1)
        expect(body[:highlight]).to include(
            fields: {
                status: {},
            },
            max_analyzed_offset: 0,
        )
    end


    it "MultiSearch / MoreLikeThis は where_or を同じ条件として処理する" do
        search_bodies = []

        search_bodies << AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields:   [:title],
            where_or: { status: "published" },
        )
        search_bodies << AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields:   [:title],
            where_or: { status: "published" },
        )

        search_bodies.each do |body|
            expect(body.dig(:query, :bool, :should)).to eq([
                {
                    term: {
                        status: "published",
                    },
                },
            ])
            expect(body.dig(:query, :bool, :minimum_should_match)).to eq(1)
        end
    end

    it "MultiSearch と MoreLikeThis は where_or を受け付け、should オプションを持たない" do
        search_modules = [
            AreSearch::MultiSearch,
            AreSearch::MoreLikeThis,
        ]

        search_modules.each do |search_module|
            expect(search_module::VALID_OPTION_KEYS).to include(
                :where,
                :where_not,
                :where_or,
            )
            expect(search_module::VALID_OPTION_KEYS).not_to include(:should)
        end

        expect(AreSearch::MultiSearch::VALID_OPTION_KEYS).not_to include(:minimum_should_match)
        expect(AreSearch::MoreLikeThis::VALID_OPTION_KEYS).to include(:minimum_should_match)
    end

    it "should は未知のオプションとして扱う" do
        expect do
            AreSearch::MultiSearch.search(
                [article_index_target],
                AreSearch::DumpBody,
                fields: [:title],
                should: [],
            )
        end.to raise_error(ArgumentError, /未知のオプション.*should/)

        expect do
            AreSearch::MoreLikeThis.search(
                [article_index_target],
                AreSearch::DumpBody,
                article_index_target,
                fields: [:title],
                should: [],
            )
        end.to raise_error(ArgumentError, /未知のオプション.*should/)
    end

    it "MultiSearch は minimum_should_match を未知のオプションとして扱う" do
        expect do
            AreSearch::MultiSearch.search(
                [article_index_target],
                AreSearch::DumpBody,
                fields:               [:title],
                minimum_should_match: 1,
            )
        end.to raise_error(ArgumentError, /未知のオプション.*minimum_should_match/)
    end

    it "runtime field を通常のフィールド指定として認識する" do
        body = AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields: [:runtime_score],
        )

        expect(body.dig(:query, :bool, :must, :combined_fields, :fields)).to eq([
            "runtime_score",
        ])
    end

    it "MoreLikeThis は fields の mapping 型と MLT オプションを ES に任せる" do
        body = AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields:               [:count],
            min_term_freq:        0,
            min_doc_freq:         -1,
            max_query_terms:      0,
            min_word_length:      0,
            minimum_should_match: "ESで判定する値",
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt[:fields]).to eq(["count"])
        expect(mlt[:min_term_freq]).to eq(0)
        expect(mlt[:min_doc_freq]).to eq(-1)
        expect(mlt[:max_query_terms]).to eq(0)
        expect(mlt[:min_word_length]).to eq(0)
        expect(mlt[:minimum_should_match]).to eq("ESで判定する値")
    end

    it "MoreLikeThis は minimum_should_match 未指定時に MLT 句へ出力しない" do
        body = AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields: [:title],
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt).not_to have_key(:minimum_should_match)
    end

    it "MoreLikeThis は where_or と MLT の minimum_should_match を別の階層へ出力する" do
        body = AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields:               [:title],
            where_or:             { status: "published" },
            minimum_should_match: "50%",
        )

        expect(body.dig(:query, :bool, :minimum_should_match)).to eq(1)
        expect(
            body.dig(:query, :bool, :must, :more_like_this, :minimum_should_match),
        ).to eq("50%")
    end

    it "複数モデル用のARオプションは Hash 構造を先に確認する" do
        expect do
            AreSearch::MultiSearch.search(
                [article_index_target],
                AreSearch::DumpBody,
                fields: [:title],
                model_results_where: [],
            )
        end.to raise_error(ArgumentError, /model_results_where は Hash/)
    end
end
