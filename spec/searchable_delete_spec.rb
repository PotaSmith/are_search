# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::IndexTarget, "delete and sync aliases" do
    def build_searchable_class
        Class.new do
            def self.table_name
                "articles"
            end

            def self.are_search_es_mappings
                {
                    default: {
                        properties: {
                            title: { type: "text" },
                        },
                    },
                }
            end

            def self.are_search_es_index_settings(_target_name)
                AreSearch.index_settings
            end
        end
    end

    before do
        allow(Rails).to receive(:logger).and_return(double("logger", debug: nil))
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")
    end

    describe "#are_search_es_delete!" do
        it "指定した id を alias から delete する" do
            model_class = build_searchable_class
            index_target = described_class.new(model_class, :default)
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            expect(client)
                .to receive(:delete)
                .with(index: "test_articles_default", id: "123")
                .and_return("result" => "deleted")

            result = index_target.are_search_es_delete!(123)

            expect(result).to eq("result" => "deleted")
        end

        it "NotFound は無視する" do
            model_class = build_searchable_class
            index_target = described_class.new(model_class, :default)
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            allow(client)
                .to receive(:delete)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            expect do
                index_target.are_search_es_delete!(123)
            end.not_to raise_error
        end

        it "NotFound 以外の例外は伝播する" do
            model_class = build_searchable_class
            index_target = described_class.new(model_class, :default)
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            allow(client)
                .to receive(:delete)
                .and_raise(RuntimeError, "delete failed")

            expect do
                index_target.are_search_es_delete!(123)
            end.to raise_error(RuntimeError, "delete failed")
        end
    end

    describe "#are_search_es_sync" do
        it "RecordSync.sync に target_name と index 名と processing_token を渡す" do
            model_class = build_searchable_class
            stub_const("Article", model_class)
            index_target = described_class.new(model_class, :default)

            allow(SecureRandom)
                .to receive(:uuid)
                .and_return("token-1")

            expect(AreSearch::RecordSync)
                .to receive(:sync)
                .with(
                    "Article",
                    :default,
                    "123",
                    "test_articles_default",
                    "token-1",
                    reraise: true,
                )

            index_target.are_search_es_sync("123", reraise: true)
        end
    end
end
