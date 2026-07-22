# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::Searcher do
    let(:model_class) do
        double(
            "Article",
            name: "Article",
        )
    end

    let(:index_target) do
        double(
            "index_target",
            model_class: model_class,
        )
    end

    before do
        allow(model_class)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)
    end

    it "ESパラメーターが不正なら指定ページを保持した空結果を返す" do
        valid_options = {
            sort: [
                {
                    _script: {
                        type: :number,
                        script: {
                            source: "doc['score'].value",
                        },
                        order: :desc,
                    },
                },
            ],
            page: 3,
            per_page: 10,
        }

        allow(AreSearch::SearchParamValidator)
            .to receive(:validate)
            .with(
                [index_target],
                [model_class],
                sort: valid_options[:sort],
                page: 3,
                per_page: 10,
            )
            .and_return(valid_options)

        query_builder = double("query_builder")
        body_builder = double("body_builder")
        query_options = valid_options.dup
        body_options = valid_options.dup
        query = { match_all: {} }
        body = {
            query: query,
            sort: valid_options[:sort],
        }

        expect(AreSearch::QueryBuilderSelector)
            .to receive(:select)
            .with(valid_options)
            .and_return(query_builder)

        expect(query_builder)
            .to receive(:build)
            .with([index_target], kind_of(Hash)) do |_index_targets, actual_options|
                actual_options.clear
                query
            end

        expect(AreSearch::BodyBuilderSelector)
            .to receive(:select)
            .with(valid_options)
            .and_return(body_builder)

        expect(body_builder)
            .to receive(:build)
            .with([index_target], query, kind_of(Hash)) do |_index_targets, _query, actual_options|
                actual_options.clear
                body
            end

        expect(AreSearch.es_search_body_policy)
            .to receive(:valid?)
            .with(body)
            .and_return(false)

        expect(AreSearch).not_to receive(:client)

        result = described_class.search(
            [index_target],
            sort: valid_options[:sort],
            page: 3,
            per_page: 10,
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(result.records).to eq([])
        expect(result.records.current_page).to eq(3)
        expect(result.records.per_page).to eq(10)
        expect(result.records.total_count).to eq(0)
    end

    it "AreSearchパラメーターの検証エラーは空結果へ変換しない" do
        allow(AreSearch::SearchParamValidator)
            .to receive(:validate)
            .and_raise(ArgumentError, "invalid option")

        expect(AreSearch::EsSearchBodyPolicy).not_to receive(:valid?)

        expect do
            described_class.search(
                [index_target],
                unknown: true,
            )
        end.to raise_error(ArgumentError, "invalid option")
    end
end
