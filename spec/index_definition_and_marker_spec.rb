# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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

RSpec.describe AreSearch::IndexDataValidator do
    describe ".find_reserved_index_field_names" do
        it "予約フィールドを Symbol key で検出する" do
            data = {
                title: "hello",
                are_search_reserved_ar_model_class_name: "Article",
            }

            result = described_class.find_reserved_index_field_names(data)

            expect(result).to eq([:are_search_reserved_ar_model_class_name])
        end

        it "予約フィールドを String key でも検出する" do
            data = {
                "title" => "hello",
                "are_search_reserved_ar_instance_key" => "123",
            }

            result = described_class.find_reserved_index_field_names(data)

            expect(result).to eq([:are_search_reserved_ar_instance_key])
        end

        it "Hash 以外なら空配列を返す" do
            result = described_class.find_reserved_index_field_names(nil)

            expect(result).to eq([])
        end
    end

    describe ".validate" do
        let(:mappings) do
            {
                properties: {
                    title:      { type: "text" },
                    status:     { type: "keyword" },
                    count:      { type: "integer" },
                    price:      { type: "float" },
                    published:  { type: "boolean" },
                    published_at: { type: "date" },
                },
            }
        end

        it "returns an empty array when data matches mappings" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
                published_at: Time.zone.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([])
        end


        it "detects string data keys" do
            data = {
                "title" => "title",
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([
                'data の key は Symbol で指定してください: "title"',
            ])
        end

        it "does not validate nested data hash keys" do
            object_mappings = {
                properties: {
                    payload: { type: "object" },
                },
            }
            data = {
                payload: {
                    "title" => "title",
                },
            }

            violations = described_class.validate(object_mappings, data)

            expect(violations).to eq([])
        end

        it "detects keys that exist only in data" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
                published_at: Time.zone.now,
                extra:        "extra",
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("mappings に定義の無いキーが data に含まれています: extra")
        end

        it "detects keys that exist only in mappings" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("mappings に定義されているキーが data にありません: published_at")
        end

        it "accepts nil values" do
            data = {
                title:        nil,
                status:       nil,
                count:        nil,
                price:        nil,
                published:    nil,
                published_at: nil,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([])
        end

        it "validates arrays by checking each element" do
            data = {
                title:        ["one", "two"],
                status:       ["published", "draft"],
                count:        [1, 2],
                price:        [1, 2.5],
                published:    [true, false],
                published_at: [Time.zone.now, Date.today],
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([])
        end

        it "detects invalid elements in arrays" do
            data = {
                title:        ["valid", 123],
                status:       ["published", :draft],
                count:        [1, 2.5],
                price:        [1.0, "2.5"],
                published:    [true, "false"],
                published_at: [Time.zone.now, :today],
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("title は text 型ですが String ではありません: Integer")
            expect(violations).to include("status は keyword 型ですが String ではありません: Symbol")
            expect(violations).to include("count は integer 型ですが Integer ではありません: Float")
            expect(violations).to include("price は float 型ですが Integer/Float ではありません: String")
            expect(violations).to include("published は boolean 型ですが true/false ではありません: String")
            expect(violations).to include("published_at は date 型ですが Date/Time/DateTime/String/Integer ではありません: Symbol")
        end

        it "detects invalid text and keyword values" do
            data = {
                title:        123,
                status:       :published,
                count:        10,
                price:        12.5,
                published:    true,
                published_at: Time.zone.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("title は text 型ですが String ではありません: Integer")
            expect(violations).to include("status は keyword 型ですが String ではありません: Symbol")
        end

        it "detects invalid integer values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10.5,
                price:        12.5,
                published:    true,
                published_at: Time.zone.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("count は integer 型ですが Integer ではありません: Float")
        end

        it "detects invalid float values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        "12.5",
                published:    true,
                published_at: Time.zone.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("price は float 型ですが Integer/Float ではありません: String")
        end

        it "detects invalid boolean values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    "true",
                published_at: Time.zone.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("published は boolean 型ですが true/false ではありません: String")
        end

        it "detects invalid date values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
                published_at: :today,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("published_at は date 型ですが Date/Time/DateTime/String/Integer ではありません: Symbol")
        end

        it "ignores unsupported mapping types" do
            unsupported_mappings = {
                properties: {
                    payload: { type: "object" },
                },
            }
            data = {
                payload: Object.new,
            }

            violations = described_class.validate(unsupported_mappings, data)

            expect(violations).to eq([])
        end

    end
end

RSpec.describe AreSearch::IndexMarker do
    let(:index_alias_name) { "test__articles__default" }

    around do |example|
        original_index_operation_enabled = AreSearch.index_operation_enabled
        AreSearch.index_operation_enabled = true

        example.run
    ensure
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    def create_index_marker(attrs = {})
        defaults = {
            index_alias_name: index_alias_name,
            operation:     "reindex",
            owner_token:   SecureRandom.uuid,
            owner_host:    "test-host",
            owner_pid:     12345,
            started_at:    Time.zone.now,
        }

        described_class.create!(defaults.merge(attrs))
    end

    describe ".marked?" do
        it "marker が無ければ false を返す" do
            expect(described_class.marked?(index_alias_name)).to eq(false)
        end

        it "marker があれば true を返す" do
            create_index_marker

            expect(described_class.marked?(index_alias_name)).to eq(true)
        end
    end

    describe ".with_index_operation_marker!" do
        it "index 操作用 marker を作成し、block の戻り値を返して marker を削除する" do
            marker_inside_block = nil

            result = described_class.with_index_operation_marker!(
                index_alias_name,
                operation: "reindex",
            ) do
                marker_inside_block = described_class.find_by(index_alias_name: index_alias_name)

                "done"
            end

            expect(result).to eq("done")
            expect(marker_inside_block).not_to eq(nil)
            expect(marker_inside_block.operation).to eq("reindex")
            expect(marker_inside_block.owner_token).not_to eq(nil)
            expect(marker_inside_block.owner_pid).to eq(Process.pid)
            expect(marker_inside_block.started_at).not_to eq(nil)
            expect(described_class.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "block で例外が出た場合も marker を削除して例外を再送出する" do
            expect do
                described_class.with_index_operation_marker!(
                    index_alias_name,
                    operation: "reindex",
                ) do
                    raise RuntimeError, "failed"
                end
            end.to raise_error(RuntimeError, "failed")

            expect(described_class.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "owner_token が変わっている marker は削除しない" do
            marker_id = nil

            described_class.with_index_operation_marker!(
                index_alias_name,
                operation: "reindex",
            ) do
                marker = described_class.find_by(index_alias_name: index_alias_name)
                marker_id = marker.id

                marker.update_columns(owner_token: "other-token")
            end

            marker = described_class.find_by(id: marker_id)

            expect(marker).not_to eq(nil)
            expect(marker.owner_token).to eq("other-token")
        end

        it "既存 marker があれば IndexMarkerUnavailable を出す" do
            create_index_marker(operation: "reindex")

            expect do
                described_class.with_index_operation_marker!(
                    index_alias_name,
                    operation: "clean_up",
                ) do
                    "not reached"
                end
            end.to raise_error(AreSearch::IndexMarkerUnavailable)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect do
                described_class.with_index_operation_marker!(
                    index_alias_name,
                    operation: "reindex",
                ) do
                    "not reached"
                end
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )

            expect(described_class.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end
    end

    describe ".create_manual!" do
        before do
            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: index_alias_name)
                .and_return(true)
        end

        it "alias が存在する場合は manual marker を作成する" do
            marker = described_class.create_manual!(index_alias_name)

            expect(marker.index_alias_name).to eq(index_alias_name)
            expect(marker.operation).to eq(described_class::MANUAL_OPERATION)
            expect(marker.owner_token).not_to eq(nil)
            expect(marker.started_at).not_to eq(nil)
        end

        it "既存 marker があれば alias を確認せず nil を返して上書きしない" do
            existing_marker = create_index_marker(operation: "reindex")

            expect(AreSearch::EsAdapter)
                .not_to receive(:index_alias_exists?)

            marker = described_class.create_manual!(index_alias_name)

            expect(marker).to eq(nil)
            expect(described_class.find_by(id: existing_marker.id).operation).to eq("reindex")
        end

        it "alias が存在しなければ nil を返して marker を作成しない" do
            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: index_alias_name)
                .and_return(false)

            marker = described_class.create_manual!(index_alias_name)

            expect(marker).to eq(nil)
            expect(described_class.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect do
                described_class.create_manual!(index_alias_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end
    end

    describe ".delete_manual!" do
        it "manual marker だけを削除する" do
            marker = create_index_marker(operation: described_class::MANUAL_OPERATION)

            deleted_count = described_class.delete_manual!(index_alias_name)

            expect(deleted_count).to eq(1)
            expect(described_class.find_by(id: marker.id)).to eq(nil)
        end

        it "manual 以外の marker は削除しない" do
            marker = create_index_marker(operation: "reindex")

            deleted_count = described_class.delete_manual!(index_alias_name)

            expect(deleted_count).to eq(0)
            expect(described_class.find_by(id: marker.id)).not_to eq(nil)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            create_index_marker(operation: described_class::MANUAL_OPERATION)
            AreSearch.index_operation_enabled = false

            expect do
                described_class.delete_manual!(index_alias_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end
    end

    describe ".delete_force!" do
        it "operation に関係なく marker を削除する" do
            marker = create_index_marker(operation: "reindex")

            deleted_count = described_class.delete_force!(index_alias_name)

            expect(deleted_count).to eq(1)
            expect(described_class.find_by(id: marker.id)).to eq(nil)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            create_index_marker(operation: "reindex")
            AreSearch.index_operation_enabled = false

            expect do
                described_class.delete_force!(index_alias_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end
    end

    describe "AreSearch manual marker API" do
        before do
            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: index_alias_name)
                .and_return(true)
        end

        it "mark_index! と unmark_index! で manual marker を操作する" do
            marker = AreSearch.mark_index!(index_alias_name)

            expect(marker.operation).to eq(described_class::MANUAL_OPERATION)
            expect(described_class.marked?(index_alias_name)).to eq(true)

            deleted_count = AreSearch.unmark_index!(index_alias_name)

            expect(deleted_count).to eq(1)
            expect(described_class.marked?(index_alias_name)).to eq(false)
        end
    end
end
