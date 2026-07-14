# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::Searcher, "filters" do
    let(:model_class) do
        AreSearch::SyncRequest
    end

    let(:index_target) do
        double(
            "index_target",
            model_class:                  model_class,
            target_name:                  :default,
            are_search_es_index_name:     "test__sync_requests__default",
            are_search_es_mappings:       {
                properties: {
                    search_text:         { type: "text" },
                    ar_model_class_name: { type: "keyword" },
                    index_target_name:   { type: "keyword" },
                    retry_count:         { type: "integer" },
                },
            },
            are_search_es_index_settings: {
                max_result_window: 2_000,
            },
        )
    end

    let(:client) do
        double("client")
    end

    before do
        allow(model_class)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(index_target)
            .to receive(:are_search_es_composite_key) do |id|
                "test__sync_requests__default/#{id}"
            end

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test__sync_requests__default")
            .and_return(true)

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
    end

    it "where、where_not、where_orを異なるbool節へ組み立てる" do
        body = described_class.search(
            [index_target],
            fields: [:search_text],
            where: {
                retry_count: {
                    term: 0,
                },
            },
            where_not: {
                ar_model_class_name: {
                    term: "Blocked",
                },
            },
            where_or: {
                index_target_name: {
                    terms: ["default", "archive"],
                },
            },
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :filter)).to include(
            {
                term: {
                    retry_count: 0,
                },
            },
            {
                bool: {
                    should: [
                        {
                            terms: {
                                index_target_name: ["default", "archive"],
                            },
                        },
                    ],
                    minimum_should_match: 1,
                },
            },
        )
        expect(body.dig(:query, :bool, :must_not)).to eq([
            {
                term: {
                    ar_model_class_name: "Blocked",
                },
            },
        ])
    end

    it "HashとArray<Hash>の条件を入力順にterm、terms、rangeへ変換する" do
        body = described_class.search(
            [index_target],
            fields: [:search_text],
            where: [
                {
                    retry_count: {
                        term: 0,
                    },
                },
                {
                    index_target_name: {
                        terms: ["default", "archive"],
                    },
                },
                {
                    retry_count: {
                        range: {
                            gte: 1,
                            lt:  10,
                        },
                    },
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :filter)).to include(
            {
                term: {
                    retry_count: 0,
                },
            },
            {
                terms: {
                    index_target_name: ["default", "archive"],
                },
            },
            {
                range: {
                    retry_count: {
                        gte: 1,
                        lt:  10,
                    },
                },
            },
        )
    end

    it "termはString、Integer、Booleanの単一値だけを受け付ける" do
        [[], {}, 1.5].each do |value|
            expect do
                described_class.search(
                    [index_target],
                    fields: [:search_text],
                    where: {
                        retry_count: {
                            term: value,
                        },
                    },
                    dump_body: true,
                )
            end.to raise_error(ArgumentError)
        end
    end

    it "termsはArrayを必要とし、各要素をString、Integer、Booleanに限定する" do
        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: {
                    index_target_name: {
                        terms: "default",
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /Array/)

        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: {
                    index_target_name: {
                        terms: ["default", {}],
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError)
    end

    it "termsの空Arrayを許可する" do
        body = described_class.search(
            [index_target],
            fields: [:search_text],
            where: {
                index_target_name: {
                    terms: [],
                },
            },
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :filter)).to include(
            terms: {
                index_target_name: [],
            },
        )
    end

    it "rangeは1件以上のHashを必要とし、各値をString、Integer、Booleanに限定する" do
        [1..10, {}, { gte: [1] }, { gte: 1.5 }].each do |value|
            expect do
                described_class.search(
                    [index_target],
                    fields: [:search_text],
                    where: {
                        retry_count: {
                            range: value,
                        },
                    },
                    dump_body: true,
                )
            end.to raise_error(ArgumentError)
        end
    end

    it "旧省略形式とfieldを持たないArray要素を拒否する" do
        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: {
                    retry_count: 0,
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError)

        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: [
                    {
                        retry_count: :retry_count,
                    },
                ],
                dump_body: true,
            )
        end.to raise_error(ArgumentError)
    end

    it "各fieldにterm、terms、rangeのいずれか1つだけを要求する" do
        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: {
                    retry_count: {
                        match: 0,
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError)

        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: {
                    retry_count: {
                        term: 0,
                        terms: [0, 1],
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /1 件/)
    end

    it "text型フィールドをwhere系条件に使用できない" do
        expect do
            described_class.search(
                [index_target],
                fields: [:search_text],
                where: {
                    search_text: {
                        term: "Rails",
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /any_non_text_without_text_fields/)
    end

    it "model_results_whereに一致するDBレコードだけを検索結果へ残す" do
        included_record = model_class.create!(
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "1",
            es_index_name:       "test__articles__default",
            request_sequence:    1,
            request_sequence_at: Time.zone.now,
            last_error:          nil,
        )
        model_class.create!(
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "2",
            es_index_name:       "test__articles__default",
            request_sequence:    2,
            request_sequence_at: Time.zone.now,
            last_error:          "blocked",
        )

        hits = []

        model_class.order(:id).each do |record|
            hits << {
                "_index" => "test__sync_requests__default",
                "_id" => record.id.to_s,
                "_source" => {
                    AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => model_class.name,
                    AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => record.id.to_s,
                },
            }
        end

        allow(client)
            .to receive(:search)
            .and_return(
                "hits" => {
                    "total" => {
                        "value" => 2,
                    },
                    "hits" => hits,
                },
            )

        result = described_class.search(
            [index_target],
            fields: [:search_text],
            model_results_where: {
                model_class => {
                    last_error: nil,
                },
            },
        )

        expect(result.records).to eq([included_record])
    end
end
