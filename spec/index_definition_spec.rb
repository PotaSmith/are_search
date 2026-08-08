# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::IndexDefinition do
    describe ".definition_name_format_description" do
        it "利用側定義名の共通形式を返す" do
            expect(described_class.definition_name_format_description).to eq(
                "小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください",
            )
        end
    end

    describe ".valid_index_prefix?" do
        it "空ではないStringを受け付ける" do
            expect(described_class.valid_index_prefix?("app_name")).to eq(true)
            expect(described_class.valid_index_prefix?("are_search_no_prefix")).to eq(true)
            expect(described_class.valid_index_prefix?("")).to eq(false)
            expect(described_class.valid_index_prefix?(:app_name)).to eq(false)
        end

        it "予約名と不正な形式を拒否する" do
            expect(
                described_class.valid_index_prefix?("are_search_reserved_ar_model_class_name"),
            ).to eq(false)
            expect(described_class.valid_index_prefix?("app__name")).to eq(false)
        end
    end

    describe ".valid_ar_table_name?" do
        it "Stringだけを受け付ける" do
            expect(described_class.valid_ar_table_name?("articles")).to eq(true)
            expect(described_class.valid_ar_table_name?(:articles)).to eq(false)
        end

        it "空文字列、予約名、不正な形式を拒否する" do
            expect(described_class.valid_ar_table_name?("")).to eq(false)
            expect(
                described_class.valid_ar_table_name?("are_search_reserved_ar_model_class_name"),
            ).to eq(false)
            expect(described_class.valid_ar_table_name?("article__items")).to eq(false)
        end
    end

    describe ".valid_index_target_name?" do
        it "Symbolだけを受け付ける" do
            expect(described_class.valid_index_target_name?(:default)).to eq(true)
            expect(described_class.valid_index_target_name?("default")).to eq(false)
        end

        it "空のSymbol、予約名、不正な形式を拒否する" do
            expect(described_class.valid_index_target_name?(:"")).to eq(false)
            expect(
                described_class.valid_index_target_name?(:are_search_reserved_ar_instance_key),
            ).to eq(false)
            expect(described_class.valid_index_target_name?(:default__index)).to eq(false)
        end
    end

    describe ".valid_index_field_name?" do
        it "Symbolだけを受け付ける" do
            expect(described_class.valid_index_field_name?(:title)).to eq(true)
            expect(described_class.valid_index_field_name?("title")).to eq(false)
        end

        it "空のSymbol、予約名、不正な形式を拒否する" do
            expect(described_class.valid_index_field_name?(:"")).to eq(false)
            expect(described_class.valid_index_field_name?(:are_search_reserved_ar_model_class_name)).to eq(false)
            expect(described_class.valid_index_field_name?(:article__title)).to eq(false)
        end
    end

    describe ".valid_sync_stage_name?" do
        it "Stringだけを受け付ける" do
            expect(described_class.valid_sync_stage_name?("default")).to eq(true)
            expect(described_class.valid_sync_stage_name?(:default)).to eq(false)
        end

        it "空文字列、予約名、不正な形式を拒否する" do
            expect(described_class.valid_sync_stage_name?("")).to eq(false)
            expect(described_class.valid_sync_stage_name?("are_search_reserved_ar_instance_key")).to eq(false)
            expect(described_class.valid_sync_stage_name?("with__file")).to eq(false)
        end
    end

    describe ".valid_index_alias_name?" do
        it "index_prefix、ar_table_name、index_target_nameからなるalias名を受け付ける" do
            expect(described_class.valid_index_alias_name?("test__articles__default")).to eq(true)
            expect(
                described_class.valid_index_alias_name?(
                    "are_search_no_prefix__articles__default",
                ),
            ).to eq(true)
        end

        it "String以外、空要素、3要素ではない名前を拒否する" do
            expect(described_class.valid_index_alias_name?(:test__articles__default)).to eq(false)
            expect(described_class.valid_index_alias_name?("__articles__default")).to eq(false)
            expect(described_class.valid_index_alias_name?("test__articles")).to eq(false)
            expect(described_class.valid_index_alias_name?("test__articles__default__extra")).to eq(false)
        end

        it "各要素をそれぞれの名前として検査する" do
            expect(described_class.valid_index_alias_name?("are_search_no_prefix2__articles__default")).to eq(true)
            expect(described_class.valid_index_alias_name?("test__are_search_no_prefix__default")).to eq(true)
            expect(described_class.valid_index_alias_name?("test__articles__are_search_no_prefix")).to eq(true)
            expect(
                described_class.valid_index_alias_name?(
                    "test__are_search_reserved_ar_model_class_name__default",
                ),
            ).to eq(false)
            expect(
                described_class.valid_index_alias_name?(
                    "test__articles__are_search_reserved_ar_instance_key",
                ),
            ).to eq(false)
            expect(described_class.valid_index_alias_name?("Test__articles__default")).to eq(false)
            expect(described_class.valid_index_alias_name?("test__Articles__default")).to eq(false)
            expect(described_class.valid_index_alias_name?("test__articles__Default")).to eq(false)
        end
    end

    describe ".valid_physical_index_name?" do
        it "正しいalias名とtimestampからなる物理index名を受け付ける" do
            expect(
                described_class.valid_physical_index_name?(
                    "test__articles__default__2026_07_03_03_10_00_123456",
                ),
            ).to eq(true)
            expect(
                described_class.valid_physical_index_name?(
                    "are_search_no_prefix__articles__default__2026_07_03_03_10_00_123456",
                ),
            ).to eq(true)
        end

        it "String以外とtimestamp形式ではない名前を拒否する" do
            expect(
                described_class.valid_physical_index_name?(
                    :test__articles__default__2026_07_03_03_10_00_123456,
                ),
            ).to eq(false)
            expect(
                described_class.valid_physical_index_name?(
                    "test__articles__default__20260703031000",
                ),
            ).to eq(false)
        end

        it "timestampより前の部分をalias名として検査する" do
            expect(
                described_class.valid_physical_index_name?(
                    "test__articles__default__extra__2026_07_03_03_10_00_123456",
                ),
            ).to eq(false)
            expect(
                described_class.valid_physical_index_name?(
                    "test__are_search_reserved_ar_model_class_name__default__2026_07_03_03_10_00_123456",
                ),
            ).to eq(false)
            expect(
                described_class.valid_physical_index_name?(
                    "test__articles__Default__2026_07_03_03_10_00_123456",
                ),
            ).to eq(false)
        end
    end

    describe "例外送出メソッド" do
        it "正しい名前なら例外を送出しない" do
            expect do
                described_class.valid_index_prefix!("app_name")
                described_class.valid_ar_table_name!("articles")
                described_class.valid_index_target_name!(:default)
                described_class.valid_index_field_name!(:title)
                described_class.valid_sync_stage_name!("default")
                described_class.valid_index_alias_name!("test__articles__default")
                described_class.valid_physical_index_name!(
                    "test__articles__default__2026_07_03_03_10_00_123456",
                )
            end.not_to raise_error
        end

        it "不正な名前なら名前ごとの固定メッセージで例外を送出する" do
            expect do
                described_class.valid_index_prefix!(:app_name)
            end.to raise_error(ArgumentError, "不正な index_prefix 名です")

            expect do
                described_class.valid_ar_table_name!(:articles)
            end.to raise_error(ArgumentError, "不正な ar_table_name 名です")

            expect do
                described_class.valid_index_target_name!("default")
            end.to raise_error(ArgumentError, "不正な index_target_name 名です")

            expect do
                described_class.valid_index_field_name!("title")
            end.to raise_error(ArgumentError, "不正な field_name 名です")

            expect do
                described_class.valid_sync_stage_name!(:default)
            end.to raise_error(ArgumentError, "不正な sync_stage_name 名です")

            expect do
                described_class.valid_index_alias_name!("invalid/index")
            end.to raise_error(ArgumentError, "不正な Elasticsearch alias 名です")

            expect do
                described_class.valid_physical_index_name!(
                    "test__articles__default",
                )
            end.to raise_error(ArgumentError, "不正な物理 index 名です")
        end
    end

    describe ".index_alias_name_from_physical_index_name" do
        it "AreSearch の物理 index 名なら末尾 timestamp を削って alias 名を返す" do
            result = described_class.index_alias_name_from_physical_index_name(
                "test__articles__default__2026_07_03_03_10_00_123456",
            )

            expect(result).to eq("test__articles__default")
        end

        it "timestamp 形式でなければ nil を返す" do
            result = described_class.index_alias_name_from_physical_index_name("test__articles__default__20260703031000")

            expect(result).to eq(nil)
        end
    end
end
