# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::IndexManager, "extra cases" do
    let(:es_index_name) { "test_articles" }
    let(:mappings) do
        {
            properties: {
                title: { type: "text" },
            },
        }
    end
    let(:index_settings) { { max_result_window: 50_000 } }
    let(:indices) { double("indices") }
    let(:client)  { double("client", indices: indices) }
    let(:logger)  { double("logger") }

    around do |example|
        Dir.mktmpdir("are_search_index_manager_extra") do |dir|
            original_lock_dir = AreSearch.lock_dir
            original_index_operation_enabled = AreSearch.index_operation_enabled
            AreSearch.lock_dir = dir

            example.run
        ensure
            AreSearch.lock_dir = original_lock_dir
            AreSearch.index_operation_enabled = original_index_operation_enabled
        end
    end

    before do
        AreSearch.index_operation_enabled = true

        allow(AreSearch).to receive(:client).and_return(client)
        allow(AreSearch).to receive(:analyzer_settings).and_return({})
        allow(indices)
            .to receive(:exists_alias)
            .with(name: es_index_name)
            .and_return(false)
        allow(logger).to receive(:warn)
        allow(logger).to receive(:info)
        allow(logger).to receive(:error)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    it "旧方式の同名実体 index があれば alias 切り替え前に削除する" do
        allow(indices)
            .to receive(:exists)
            .with(index: es_index_name)
            .and_return(true)

        allow(indices)
            .to receive(:delete)
            .with(index: es_index_name)
            .and_raise(RuntimeError, "delete failed")

        allow(indices).to receive(:create)

        expect(indices).not_to receive(:update_aliases)

        expect do
            described_class.es_reindex(es_index_name, index_settings, mappings) do
                []
            end
        end.to raise_error(RuntimeError, "delete failed")

        marker = AreSearch::IndexMarker.find_by(es_index_name: es_index_name)

        expect(marker).to eq(nil)
    end

    it "alias 切り替えで例外が出た場合も marker を削除して例外を再送出する" do
        allow(indices)
            .to receive(:exists)
            .with(index: es_index_name)
            .and_return(false)

        allow(indices).to receive(:create)

        allow(indices)
            .to receive(:get_alias)
            .with(name: es_index_name)
            .and_raise(Elastic::Transport::Transport::Errors::NotFound)

        allow(indices)
            .to receive(:update_aliases)
            .and_raise(RuntimeError, "alias failed")

        expect do
            described_class.es_reindex(es_index_name, index_settings, mappings) do
                []
            end
        end.to raise_error(RuntimeError, "alias failed")

        marker = AreSearch::IndexMarker.find_by(es_index_name: es_index_name)

        expect(marker).to eq(nil)
    end
end
