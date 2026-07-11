# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::Reindexer do
    let(:mappings) do
        {
            properties: {
                id:    { type: "long" },
                title: { type: "text" },
            },
        }
    end

    let(:mappings_for_index) do
        {
            properties: {
                id:    { type: "long" },
                title: { type: "text" },
                are_search_es_ar_model_class_name: AreSearch::RESERVED_ES_FIELD_NAME_SETTING,
                are_search_es_ar_instance_key:     AreSearch::RESERVED_ES_FIELD_NAME_SETTING,
            },
        }
    end

    let(:index_settings) do
        { max_result_window: 50_000 }
    end

    let(:model) do
        class_double(
            "Article",
            count: record_count,
        )
    end

    let(:index_target) do
        double(
            "index_target",
            model_class:                    model,
            target_name:                    :default,
            are_search_es_index_name:       "test_articles_default",
            are_search_es_mappings:         mappings,
            are_search_es_mappings_for_index: mappings_for_index,
            are_search_es_index_settings:   index_settings,
        )
    end

    let(:client) do
        instance_double("Elasticsearch::Client")
    end

    let(:progress_bar_class) do
        Class.new do
            attr_reader :increments

            def initialize(_total)
                @increments = []
            end

            def increment!(size)
                @increments << size
            end
        end
    end

    before do
        allow(AreSearch).to receive(:client).and_return(client)
        stub_const("ProgressBar", progress_bar_class)

        logger = instance_double("Logger", error: nil)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    describe ".reindex_index_target" do
        context "when all bulk requests succeed" do
            let(:record_count) do
                2
            end

            it "delegates index guard and bulk indexes records into the yielded physical index" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 2, title: "second" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                end

                expected_body = [
                    { index: { _index: "test_articles_20240101120000", _id: "1" } },
                    { id: 1, title: "first" },
                    { index: { _index: "test_articles_20240101120000", _id: "2" } },
                    { id: 2, title: "second" },
                ]

                expect(AreSearch::IndexManager).to receive(:es_reindex) do |index_name, actual_index_settings, index_mappings, &block|
                    expect(index_name).to eq("test_articles_default")
                    expect(actual_index_settings).to eq(index_settings)
                    expect(index_mappings).to eq(mappings_for_index)

                    block.call("test_articles_20240101120000")
                end

                expect(client).to receive(:bulk)
                    .with(body: expected_body)
                    .and_return("errors" => false, "items" => [])

                result = described_class.reindex_index_target(index_target)

                expect(result).to eq([])
            end
        end

        context "when Elasticsearch reports item errors" do
            let(:record_count) do
                2
            end

            it "returns failed ids without hiding successful ids" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 2, title: "second" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                end

                allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _index_mappings, &block|
                    block.call("test_articles_20240101120000")
                end

                response = {
                    "errors" => true,
                    "items"  => [
                        {
                            "index" => {
                                "_id" => "1",
                            },
                        },
                        {
                            "index" => {
                                "_id"   => "2",
                                "error" => { "type" => "mapper_parsing_exception" },
                            },
                        },
                    ],
                }

                allow(client).to receive(:bulk).and_return(response)

                result = described_class.reindex_index_target(index_target)

                expect(result).to eq(["2"])
            end
        end

        context "when some records are not indexable" do
            let(:record_count) do
                2
            end

            it "does not add non-indexable records to bulk body" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_es_indexable?: false,
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                end

                allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _index_mappings, &block|
                    block.call("test_articles_20240101120000")
                end

                expect(client).to receive(:bulk)
                    .with(
                        body: [
                            { index: { _index: "test_articles_20240101120000", _id: "1" } },
                            { id: 1, title: "first" },
                        ],
                    )
                    .and_return("errors" => false, "items" => [])

                result = described_class.reindex_index_target(index_target)

                expect(result).to eq([])
            end
        end

        context "when multiple batches are processed" do
            let(:record_count) do
                3
            end

            it "calls bulk once for each batch" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 2, title: "second" },
                )
                third_record = instance_double(
                    "Article",
                    id: 3,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 3, title: "third" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                    block.call([third_record])
                end

                allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _index_mappings, &block|
                    block.call("test_articles_20240101120000")
                end

                expect(client).to receive(:bulk)
                    .with(
                        body: [
                            { index: { _index: "test_articles_20240101120000", _id: "1" } },
                            { id: 1, title: "first" },
                            { index: { _index: "test_articles_20240101120000", _id: "2" } },
                            { id: 2, title: "second" },
                        ],
                    )
                    .and_return("errors" => false, "items" => [])

                expect(client).to receive(:bulk)
                    .with(
                        body: [
                            { index: { _index: "test_articles_20240101120000", _id: "3" } },
                            { id: 3, title: "third" },
                        ],
                    )
                    .and_return("errors" => false, "items" => [])

                result = described_class.reindex_index_target(index_target)

                expect(result).to eq([])
            end
        end

        context "when bulk raises" do
            let(:record_count) do
                1
            end

            it "例外を握りつぶさない" do
                record = instance_double(
                    "Article",
                    id: 1,
                    are_search_es_indexable?: true,
                    are_search_es_data_for_index!: { id: 1, title: "first" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([record])
                end

                allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _mappings, &block|
                    block.call("test_articles_2024_01_01_00_00_00_000000")
                end

                allow(client)
                    .to receive(:bulk)
                    .and_raise(RuntimeError, "bulk failed")

                expect do
                    described_class.reindex_index_target(index_target)
                end.to raise_error(RuntimeError, "bulk failed")
            end
        end

        context "when data for index raises" do
            let(:record_count) do
                1
            end

            it "例外を握りつぶさず bulk しない" do
                record = instance_double(
                    "Article",
                    id: 1,
                    are_search_es_indexable?: true,
                )

                allow(record)
                    .to receive(:are_search_es_data_for_index!)
                    .with(index_target)
                    .and_raise(AreSearch::Error, "reserved field")

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([record])
                end

                allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _mappings, &block|
                    block.call("test_articles_2024_01_01_00_00_00_000000")
                end

                expect(client).not_to receive(:bulk)

                expect do
                    described_class.reindex_index_target(index_target)
                end.to raise_error(AreSearch::Error, "reserved field")
            end
        end

        context "when the model has no records" do
            let(:record_count) do
                0
            end

            it "does not create ProgressBar or call bulk and returns an empty failed id list" do
                allow(model).to receive(:find_in_batches)

                allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _index_mappings, &block|
                    block.call("test_articles_20240101120000")
                end

                expect(ProgressBar).not_to receive(:new)
                expect(client).not_to receive(:bulk)

                result = described_class.reindex_index_target(index_target)

                expect(result).to eq([])
            end
        end
    end
end
