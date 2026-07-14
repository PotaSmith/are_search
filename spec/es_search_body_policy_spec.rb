# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::EsSearchBodyPolicy do
    describe ".invalid_key?" do
        it "script に完全一致するキーを拒否する" do
            expect(described_class.invalid_key?(:script)).to eq(true)
        end

        it "script_ で始まるキーを拒否する" do
            expect(described_class.invalid_key?(:script_score)).to eq(true)
            expect(described_class.invalid_key?("script_fields")).to eq(true)
        end

        it "_script で終わるキーを拒否する" do
            expect(described_class.invalid_key?(:_script)).to eq(true)
            expect(described_class.invalid_key?("map_script")).to eq(true)
        end

        it "script を途中に含むだけのキーは拒否しない" do
            expect(described_class.invalid_key?(:description)).to eq(false)
            expect(described_class.invalid_key?(:transcript)).to eq(false)
            expect(described_class.invalid_key?(:subscription)).to eq(false)
        end
    end

    describe ".valid?" do
        it "script系のキーが無ければtrueを返す" do
            es_params = {
                query: {
                    bool: {
                        filter: [
                            { term: { status: "published" } },
                        ],
                    },
                },
                sort: [
                    { updated_at: :desc },
                ],
            }

            expect(described_class.valid?(es_params)).to eq(true)
        end

        it "scriptキーがあればfalseを返す" do
            es_params = {
                aggs: {
                    category_id: {
                        terms: {
                            script: {
                                source: "doc['category_id'].value",
                            },
                        },
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "_scriptキーがあればfalseを返す" do
            es_params = {
                sort: [
                    {
                        _script: {
                            type: :number,
                            order: :desc,
                        },
                    },
                ],
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "script_で始まるキーがあればfalseを返す" do
            es_params = {
                query: {
                    script_score: {
                        query: {
                            match_all: {},
                        },
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "_scriptで終わるStringキーもfalseを返す" do
            es_params = {
                "runtime_mappings" => {
                    "score" => {
                        "map_script" => {
                            "source" => "emit(1)",
                        },
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "scriptという通常フィールド名もfalseを返す" do
            es_params = {
                query: {
                    term: {
                        script: "latin",
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "scriptを途中に含む通常フィールド名ならtrueを返す" do
            es_params = {
                query: {
                    bool: {
                        filter: [
                            { term: { description: "description" } },
                            { term: { transcript: "transcript" } },
                            { term: { subscription: "subscription" } },
                        ],
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(true)
        end

        it "値にscriptが含まれるだけならtrueを返す" do
            es_params = {
                query: {
                    term: {
                        category: "javascript",
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(true)
        end
    end
end
