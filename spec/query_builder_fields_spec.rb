# frozen_string_literal: true

require "spec_helper"

RSpec.describe "query builder fields" do
    let(:article_model) do
        Class.new do
            # Searcherがモデル識別条件を作成できるよう固定名を返す。
            def self.name
                "Article"
            end

            # QueryBuilderの検査に必要なSearchable判定だけを成立させる。
            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end
        end
    end

    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                  article_model,
            target_name:                  :default,
            are_search_es_index_name:     "test__articles__default",
            are_search_es_mappings:       {
                properties: {
                    title: { type: "text" },
                    body:  { type: "text" },
                },
            },
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end

    it "1件の標準検索のArray形式をcombined_fieldsへ変換する" do
        source_fields = [:title, :body]

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       source_fields,
                },
            ],
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :combined_fields, :fields),
        ).to eq([
            "title",
            "body",
        ])
        expect(source_fields).to eq([:title, :body])
    end

    it "1件の標準検索のHash形式をboost付きcombined_fieldsへ変換する" do
        source_fields = {
            title: 2.0,
            body:  1,
        }

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       source_fields,
                },
            ],
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :combined_fields, :fields),
        ).to eq([
            "title^2.0",
            "body^1",
        ])
        expect(source_fields).to eq(
            title: 2.0,
            body:  1,
        )
    end


    it "query_typeでsimple_query_stringへ切り替える" do
        query_string = 'Ruby + (Rails | Elasticsearch) -"Java VM"'

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: query_string,
                    fields: {
                        title: 2.0,
                        body:  1,
                    },
                    query_type: AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                simple_query_string: {
                    query:            query_string,
                    fields:           ["title^2.0", "body^1"],
                    default_operator: "and",
                    flags:            "AND|OR|NOT|PHRASE|PRECEDENCE|WHITESPACE|ESCAPE",
                },
            },
        ])
    end

    it "simple_query_stringの検索文字列を変換せずそのまま渡す" do
        query_string = 'C++ AND A|B OR -draft OR path\\name OR "Ruby on Rails"'

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: query_string,
                    fields:       [:title],
                    query_type:   AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                },
            ],
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :simple_query_string, :query),
        ).to eq(query_string)
    end

    it "queries配下でquery_typeを個別に指定する" do
        simple_query = 'Ruby | "Ruby on Rails"'

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
                {
                    query_string: simple_query,
                    fields:       [:title, :body],
                    query_type:   AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title"],
                    operator: "and",
                },
            },
            {
                simple_query_string: {
                    query:            simple_query,
                    fields:           ["title", "body"],
                    default_operator: "and",
                    flags:            "AND|OR|NOT|PHRASE|PRECEDENCE|WHITESPACE|ESCAPE",
                },
            },
        ])
    end

    it "queries配下の空文字列と空白だけの検索語は全文検索句を作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
                {
                    query_string: "   ",
                    fields:       [:body],
                },
                {
                    query_string: "Rails",
                    fields:       [:title, :body],
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title", "body"],
                    operator: "and",
                },
            },
        ])
    end

    it "queries配下の検索語がすべて空の場合はmustを作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
                {
                    query_string: "   ",
                    fields:       [:body],
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool)).not_to have_key(:must)
    end

    it "queries配下のArray形式とHash形式を個別に変換する" do
        source_queries = [
            {
                query_string: "Rails",
                fields: [:title, :body],
            },
            {
                query_string: "Ruby",
                fields: {
                    title: 3.0,
                    body:  1,
                },
            },
        ]

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries:   source_queries,
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title", "body"],
                    operator: "and",
                },
            },
            {
                combined_fields: {
                    query:    "Ruby",
                    fields:   ["title^3.0", "body^1"],
                    operator: "and",
                },
            },
        ])
        expect(source_queries[0][:fields]).to eq([:title, :body])
        expect(source_queries[1][:fields]).to eq(
            title: 3.0,
            body:  1,
        )
    end
end
