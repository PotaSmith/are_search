# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::IndexManager do
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
        Dir.mktmpdir("are_search_index_manager") do |dir|
            original_lock_dir = AreSearch.lock_dir
            original_index_operation_enabled = AreSearch.index_operation_enabled
            AreSearch.lock_dir = dir

            example.run
        ensure
            AreSearch.lock_dir = original_lock_dir
            AreSearch.index_operation_enabled = original_index_operation_enabled
        end
    end


    def alias_response_for(*physical_names)
        # Elasticsearch indices.get_alias は、alias が指す物理 index 名を
        # response の key として返す。
        response = {}

        physical_names.each do |physical_name|
            response[physical_name] = {}
        end

        response
    end

    def create_index_marker(es_index_name, operation: "reindex", message: nil)
        AreSearch::IndexMarker.create!(
            es_index_name: es_index_name,
            operation:     operation,
            owner_token:   SecureRandom.uuid,
            owner_host:    "test-host",
            owner_pid:     12345,
            started_at:    Time.zone.now,
            message:       message,
        )
    end

    before do
        AreSearch.index_operation_enabled = true

        allow(AreSearch).to receive(:client).and_return(client)
        allow(AreSearch)
            .to receive(:analyzer_settings)
            .and_return(analysis: {})
        allow(indices)
            .to receive(:exists_alias)
            .with(name: es_index_name)
            .and_return(false)

        allow(logger).to receive(:warn)
        allow(logger).to receive(:info)
        allow(logger).to receive(:error)
        allow(Rails).to receive(:logger).and_return(logger)
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

    describe ".es_index_locked?" do
        it "互換用に IndexMarker.marked? の結果を返す" do
            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with(es_index_name)
                .and_return(true)

            expect(described_class.es_index_locked?(es_index_name)).to eq(true)
        end
    end

    describe ".es_get_alias_physical_names" do
        it "alias が指している物理 index 名を返す" do
            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_return(alias_response_for("test_articles__2024_01_01_00_00_00_000000"))

            result = described_class.es_get_alias_physical_names(es_index_name)

            expect(result).to eq(["test_articles__2024_01_01_00_00_00_000000"])
        end

        it "alias が無ければ空配列を返す" do
            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            result = described_class.es_get_alias_physical_names(es_index_name)

            expect(result).to eq([])
        end
    end

    describe ".es_index_status" do
        it "別 target の物理 index を状態確認から除外する" do
            current_physical_name = "test_articles__2026_07_14_00_00_00_000000"
            other_target_physical_name = "test_articles__archive__2026_07_15_00_00_00_000000"

            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_return(alias_response_for(current_physical_name))

            allow(indices)
                .to receive(:get)
                .with(index: "#{es_index_name}__*")
                .and_return(
                    {
                        current_physical_name      => {},
                        other_target_physical_name => {},
                    },
                )

            allow(indices)
                .to receive(:get)
                .with(index: es_index_name)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            status = described_class.es_index_status(es_index_name)

            expect(status[:physical_indexes]).to eq([
                {
                    name:    current_physical_name,
                    current: true,
                },
            ])
            expect(status[:newest_physical_name]).to eq(current_physical_name)
            expect(status[:warnings]).to eq([])
        end
    end

    describe ".es_reindex" do

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect(indices).not_to receive(:exists)
            expect(indices).not_to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.es_reindex(es_index_name, index_settings, mappings) do
                    []
                end
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end

        it "bulk 投入成功時は alias を新しい物理 index に切り替える" do
            created_index = nil
            block_index = nil
            alias_actions = nil

            allow(indices)
                .to receive(:exists)
                .with(index: es_index_name)
                .and_return(false)

            allow(indices)
                .to receive(:create) do |args|
                    created_index = args[:index]
                    expect(args[:body]).to eq(
                        settings: {
                            analysis: {},
                            index:    index_settings,
                        },
                        mappings: mappings,
                    )
                end

            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_return(alias_response_for("test_articles__2023_12_01_00_00_00_000000"))

            expect(indices)
                .to receive(:update_aliases) do |args|
                    alias_actions = args[:body][:actions]
                end

            result = described_class.es_reindex(es_index_name, index_settings, mappings) do |physical_index|
                block_index = physical_index
                []
            end

            expect(result).to eq([])
            expect(block_index).to eq(created_index)
            expect(created_index).to match(
                /\Atest_articles__\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}_\d{6}\z/,
            )
            expect(alias_actions).to eq([
                { remove: { index: "test_articles__2023_12_01_00_00_00_000000", alias: es_index_name } },
                { add: { index: created_index, alias: es_index_name } },
            ])
            expect(AreSearch::IndexMarker.find_by(es_index_name: es_index_name)).to eq(nil)
        end

        it "bulk 投入に失敗 ID があれば alias を切り替えず標準出力にも出す" do
            created_index = nil
            result = nil

            allow(indices)
                .to receive(:exists)
                .with(index: es_index_name)
                .and_return(false)

            allow(indices)
                .to receive(:create) do |args|
                    created_index = args[:index]
                end

            expect(indices).not_to receive(:update_aliases)
            expect(logger).to receive(:error) do |&block|
                expect(block.call).to include("alias を切り替えませんでした")
                expect(block.call).to include("failed_ids=[\"1\", \"2\"]")
            end

            expect do
                result = described_class.es_reindex(es_index_name, index_settings, mappings) do |physical_index|
                    expect(physical_index).to eq(created_index)
                    ["1", "2"]
                end
            end.to output(/alias を切り替えませんでした.*failed_ids=\["1", "2"\]/).to_stdout

            expect(result).to eq(["1", "2"])
            expect(AreSearch::IndexMarker.find_by(es_index_name: es_index_name)).to eq(nil)
        end

        it "旧方式の同名実体 index があれば bulk 投入成功後、alias 切り替え前に削除する" do
            deleted_indices = []

            allow(indices)
                .to receive(:exists)
                .with(index: es_index_name)
                .and_return(true)

            allow(indices)
                .to receive(:delete) do |args|
                    deleted_indices << args[:index]
                end

            allow(indices).to receive(:create)

            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            allow(indices).to receive(:update_aliases)

            result = described_class.es_reindex(es_index_name, index_settings, mappings) do
                []
            end

            expect(result).to eq([])
            expect(deleted_indices).to eq([es_index_name])
        end

        it "旧方式の同名実体 index の削除に失敗した場合は marker を削除して例外を再送出する" do
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

        it "処理中に例外が出た場合も marker を削除して例外を再送出する" do
            allow(indices)
                .to receive(:exists)
                .with(index: es_index_name)
                .and_return(false)

            allow(indices).to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.es_reindex(es_index_name, index_settings, mappings) do
                    raise "bulk failed"
                end
            end.to raise_error(RuntimeError, "bulk failed")

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

        it "処理中の例外後に marker 削除も失敗した場合は削除失敗例外を出し元例外を cause に残す" do
            allow(indices)
                .to receive(:exists)
                .with(index: es_index_name)
                .and_return(false)

            allow(indices).to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            allow(AreSearch::IndexMarker)
                .to receive(:where)
                .and_call_original

            allow(AreSearch::IndexMarker)
                .to receive(:where)
                .with(
                    id:          kind_of(Integer),
                    owner_token: kind_of(String),
                )
                .and_raise(RuntimeError, "marker delete failed")

            raised_error = nil

            begin
                described_class.es_reindex(es_index_name, index_settings, mappings) do
                    raise "bulk failed"
                end
            rescue RuntimeError => e
                raised_error = e
            end

            expect(raised_error.message).to eq("marker delete failed")
            expect(raised_error.cause.message).to eq("bulk failed")
        end

        it "marker が残っている場合は false を返す" do
            create_index_marker(es_index_name)

            expect(indices).not_to receive(:exists)
            expect(indices).not_to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            result = described_class.es_reindex(es_index_name, index_settings, mappings) do
                []
            end

            expect(result).to eq(false)
            expect(AreSearch::IndexMarker.marked?(es_index_name)).to eq(true)
        end
    end

    describe ".es_clean_up" do

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect(indices).not_to receive(:get_alias)
            expect(indices).not_to receive(:get)
            expect(indices).not_to receive(:delete)

            expect do
                described_class.es_clean_up(es_index_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end

        it "alias が指していない物理 index だけ削除する" do
            deleted_indices = []

            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_return(alias_response_for("test_articles__2024_01_02_00_00_00_000000"))

            allow(indices)
                .to receive(:get)
                .with(index: "#{es_index_name}__*")
                .and_return(
                    {
                        "test_articles__2024_01_01_00_00_00_000000" => {},
                        "test_articles__2024_01_02_00_00_00_000000" => {},
                        "test_articles__2024_01_03_00_00_00_000000" => {},
                    },
                )

            allow(indices)
                .to receive(:delete) do |args|
                    deleted_indices << args[:index]
                end

            result = described_class.es_clean_up(es_index_name)

            expect(result).to eq(true)
            expect(deleted_indices).to eq([
                "test_articles__2024_01_01_00_00_00_000000",
                "test_articles__2024_01_03_00_00_00_000000",
            ])
            expect(AreSearch::IndexMarker.find_by(es_index_name: es_index_name)).to eq(nil)
        end

        it "別 target の物理 index は削除しない" do
            current_physical_name = "test_articles__2026_07_14_00_00_00_000000"
            old_physical_name = "test_articles__2026_07_13_00_00_00_000000"
            other_target_physical_name = "test_articles__archive__2026_07_12_00_00_00_000000"
            arbitrary_suffix_index_name = "test_articles_backup"
            deleted_indices = []

            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_return(alias_response_for(current_physical_name))

            allow(indices)
                .to receive(:get)
                .with(index: "#{es_index_name}__*")
                .and_return(
                    {
                        current_physical_name      => {},
                        old_physical_name           => {},
                        other_target_physical_name  => {},
                        arbitrary_suffix_index_name => {},
                    },
                )

            allow(indices)
                .to receive(:delete) do |args|
                    deleted_indices << args[:index]
                end

            result = described_class.es_clean_up(es_index_name)

            expect(result).to eq(true)
            expect(deleted_indices).to eq([old_physical_name])
        end

        it "削除中に例外が出た場合も marker を削除して例外を再送出する" do
            allow(indices)
                .to receive(:get_alias)
                .with(name: es_index_name)
                .and_return(alias_response_for("test_articles__2024_01_02_00_00_00_000000"))

            allow(indices)
                .to receive(:get)
                .with(index: "#{es_index_name}__*")
                .and_return(
                    {
                        "test_articles__2024_01_01_00_00_00_000000" => {},
                        "test_articles__2024_01_02_00_00_00_000000" => {},
                    },
                )

            allow(indices)
                .to receive(:delete)
                .with(index: "test_articles__2024_01_01_00_00_00_000000")
                .and_raise(RuntimeError, "delete failed")

            expect do
                described_class.es_clean_up(es_index_name)
            end.to raise_error(RuntimeError, "delete failed")

            marker = AreSearch::IndexMarker.find_by(es_index_name: es_index_name)

            expect(marker).to eq(nil)
        end

        it "marker が残っている場合は false を返す" do
            create_index_marker(es_index_name, operation: "clean_up")

            expect(indices).not_to receive(:get_alias)
            expect(indices).not_to receive(:get)
            expect(indices).not_to receive(:delete)

            result = described_class.es_clean_up(es_index_name)

            expect(result).to eq(false)
            expect(AreSearch::IndexMarker.marked?(es_index_name)).to eq(true)
        end
    end

    describe ".es_with_index_guard" do
        it "flock と marker の内側で block を実行し戻り値を返す" do
            marker_in_block = nil

            result = described_class.es_with_index_guard(
                es_index_name,
                operation: "pdf_extract",
            ) do
                marker_in_block = AreSearch::IndexMarker.find_by(
                    es_index_name: es_index_name,
                )

                "done"
            end

            expect(result).to eq("done")
            expect(marker_in_block).not_to eq(nil)
            expect(marker_in_block.operation).to eq("pdf_extract")
            expect(AreSearch::IndexMarker.marked?(es_index_name)).to eq(false)
        end

        it "block で例外が出た場合も marker を削除して例外を再送出する" do
            expect do
                described_class.es_with_index_guard(
                    es_index_name,
                    operation: "pdf_extract",
                ) do
                    raise RuntimeError, "extract failed"
                end
            end.to raise_error(RuntimeError, "extract failed")

            expect(AreSearch::IndexMarker.marked?(es_index_name)).to eq(false)
        end

        it "marker が残っている場合は block を実行せず false を返す" do
            create_index_marker(es_index_name, operation: "reindex")
            block_called = false

            result = described_class.es_with_index_guard(
                es_index_name,
                operation: "pdf_extract",
            ) do
                block_called = true
            end

            expect(result).to eq(false)
            expect(block_called).to eq(false)
            expect(AreSearch::IndexMarker.marked?(es_index_name)).to eq(true)
        end

        it "flock を別プロセス相当の処理が取得済みなら block を実行せず false を返す" do
            lock_path = AreSearch.index_lock_file_path(es_index_name)
            FileUtils.mkdir_p(File.dirname(lock_path))
            block_called = false

            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)
                expect(locked).to eq(0)

                result = described_class.es_with_index_guard(
                    es_index_name,
                    operation: "pdf_extract",
                ) do
                    block_called = true
                end

                expect(result).to eq(false)
            end

            expect(block_called).to eq(false)
            expect(AreSearch::IndexMarker.marked?(es_index_name)).to eq(false)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect do
                described_class.es_with_index_guard(
                    es_index_name,
                    operation: "pdf_extract",
                ) do
                    "not reached"
                end
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end

        it "operation が空なら ArgumentError を出す" do
            expect do
                described_class.es_with_index_guard(
                    es_index_name,
                    operation: nil,
                ) do
                    "not reached"
                end
            end.to raise_error(ArgumentError, "operation を指定してください")
        end

        it "block が無ければ ArgumentError を出す" do
            expect do
                described_class.es_with_index_guard(
                    es_index_name,
                    operation: "pdf_extract",
                )
            end.to raise_error(ArgumentError, "es_with_index_guard には block が必要です")
        end
    end

    describe ".es_delete_index!" do
        it "指定された物理 index を削除する" do
            expect(indices)
                .to receive(:delete)
                .with(index: "test_articles__2024_01_01_00_00_00_000000")

            described_class.es_delete_index!("test_articles__2024_01_01_00_00_00_000000")
        end
    end
end
