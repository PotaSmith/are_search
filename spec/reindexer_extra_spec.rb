# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::Reindexer, "extra cases" do
    let(:mappings) do
        {
            properties: {
                id:    { type: "long" },
                title: { type: "text" },
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
            are_search_es_index_settings:   index_settings,
        )
    end
    let(:client) { instance_double("Elasticsearch::Client") }
    let(:logger) { instance_double("Logger", error: nil) }

    before do
        allow(AreSearch).to receive(:client).and_return(client)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    context "when bulk raises" do
        let(:record_count) { 1 }

        it "例外を握りつぶさない" do
            record = instance_double(
                "Article",
                id: 1,
                are_search_es_indexable?: true,
                are_search_es_data: { id: 1, title: "first" },
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

    context "when the model has no records" do
        let(:record_count) { 0 }

        it "ProgressBar を作らない" do
            allow(model).to receive(:find_in_batches)
            stub_const("ProgressBar", class_double("ProgressBar"))

            allow(AreSearch::IndexManager).to receive(:es_reindex) do |_index_name, _index_settings, _mappings, &block|
                block.call("test_articles_2024_01_01_00_00_00_000000")
            end

            expect(ProgressBar).not_to receive(:new)

            result = described_class.reindex_index_target(index_target)

            expect(result).to eq([])
        end
    end
end
