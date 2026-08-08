# frozen_string_literal: true

RSpec.describe AreSearch do
    it "has a version number" do
        expect(AreSearch::VERSION).not_to be nil
    end

    describe ".default_aggs_size" do
        it "aggs の Array 簡易形式で使用する bucket 数を返す" do
            expect(described_class.default_aggs_size).to eq(
                AreSearch::StandardBodyBuilder::DEFAULT_AGGS_SIZE,
            )
        end
    end

    describe "内部定義" do
        it "設定値の検査に使う定数を公開しない" do
            expect(described_class.const_defined?(:ANALYZER_SETTINGS, false)).to eq(false)
            expect(described_class.const_defined?(:DEFAULT_AGGS_SIZE, false)).to eq(false)

            expect do
                described_class::DEFAULT_ANALYZER_SETTINGS
            end.to raise_error(NameError)

            expect do
                described_class::AFTER_COMMIT_MODES
            end.to raise_error(NameError)

            expect do
                described_class::SEARCH_FAILURE_MODES
            end.to raise_error(NameError)
        end

        it "client 設定のログ出力メソッドを公開しない" do
            expect(described_class.respond_to?(:log_client_config)).to eq(false)
            expect(described_class.respond_to?(:log_client_config, true)).to eq(true)
        end
    end

    describe ".query_type_combined_fields" do
        it "combined_fields の query_type を返す" do
            expect(described_class.query_type_combined_fields).to eq(
                AreSearch::StandardQueryBuilder::TYPE_COMBINED_FIELDS,
            )
        end
    end

    describe ".query_type_simple_query_string" do
        it "simple_query_string の query_type を返す" do
            expect(described_class.query_type_simple_query_string).to eq(
                AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
            )
        end
    end

    describe ".join_index_name" do
        it "index 名の要素を AreSearch の区切り文字で連結する" do
            result = described_class.join_index_name(
                "test",
                "articles",
                "*",
            )

            expect(result).to eq("test__articles__*")
        end
    end

    describe ".delete_physical_index!" do
        it "物理 index 名でなければ拒否する" do
            expect(AreSearch::IndexManager)
                .not_to receive(:delete_physical_index!)

            expect do
                described_class.delete_physical_index!(
                    "test__articles__default",
                )
            end.to raise_error(ArgumentError, "不正な物理 index 名です")
        end

        it "物理 index の削除を IndexManager へ委譲する" do
            physical_index_name =
                "test__articles__default__2026_07_04_10_00_00_000000"

            expect(AreSearch::IndexManager)
                .to receive(:delete_physical_index!)
                .with(physical_index_name)
                .and_return(:deleted)

            result = described_class.delete_physical_index!(
                physical_index_name,
            )

            expect(result).to eq(:deleted)
        end
    end
end
