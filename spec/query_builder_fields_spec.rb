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
            are_search_es_index_name:     "test_articles_default",
            are_search_es_mappings:       {
                properties: {
                    title: { type: "text" },
                    body:  { type: "text" },
                },
            },
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end

    it "単純検索のArray形式をcombined_fieldsへ変換する" do
        source_fields = [:title, :body]

        body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "Rails",
            fields:       source_fields,
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, :combined_fields, :fields),
        ).to eq([
            "title",
            "body",
        ])
        expect(source_fields).to eq([:title, :body])
    end

    it "単純検索のHash形式をboost付きcombined_fieldsへ変換する" do
        source_fields = {
            title: 2.0,
            body:  1,
        }

        body = AreSearch::Searcher.search(
            [article_index_target],
            query_string: "Rails",
            fields:       source_fields,
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, :combined_fields, :fields),
        ).to eq([
            "title^2.0",
            "body^1",
        ])
        expect(source_fields).to eq(
            title: 2.0,
            body:  1,
        )
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
