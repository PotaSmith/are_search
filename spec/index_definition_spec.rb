# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::IndexDefinition do
    describe ".valid_es_index_name_element?" do
        it "小文字英字で始まる小文字英字とアンダーバーを受け付ける" do
            expect(described_class.valid_es_index_name_element?("articles")).to eq(true)
            expect(described_class.valid_es_index_name_element?("article_items")).to eq(true)
        end

        it "形式外の値を拒否する" do
            expect(described_class.valid_es_index_name_element?("Article")).to eq(false)
            expect(described_class.valid_es_index_name_element?("article-1")).to eq(false)
            expect(described_class.valid_es_index_name_element?(:articles)).to eq(false)
        end
    end

    describe ".es_alias_name_from_index_name" do
        it "AreSearch の物理 index 名なら末尾 timestamp を削って alias 名を返す" do
            result = described_class.es_alias_name_from_index_name(
                "test__articles__default__2026_07_03_03_10_00_123456",
            )

            expect(result).to eq("test__articles__default")
        end

        it "timestamp 形式でなければ nil を返す" do
            result = described_class.es_alias_name_from_index_name("test__articles__default__20260703031000")

            expect(result).to eq(nil)
        end
    end
end
