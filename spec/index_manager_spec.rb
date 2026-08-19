# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::IndexManager do
    let(:index_alias_name) { "test__articles__default" }
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
        response = {}

        physical_names.each do |physical_name|
            response[physical_name] = {
                "aliases" => {
                    index_alias_name => {},
                },
            }
        end

        response
    end

    def create_sync_lock(index_alias_name, operation: "reindex", message: nil)
        AreSearch::SyncLock.create!(
            index_alias_name: index_alias_name,
            sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            operation:        operation,
            owner_token:   SecureRandom.uuid,
            owner_host:    "test-host",
            owner_pid:     12345,
            started_at:    Time.zone.now,
            message:       message,
        )
    end

    def build_reindex_result
        {
            result: :not_success,
            message: '',
            failed_ids: [],
            stop_phase: nil,
            done_phases: [],
        }
    end

    before do
        AreSearch.index_operation_enabled = true

        allow(AreSearch).to receive(:client).and_return(client)
        allow(AreSearch)
            .to receive(:analyzer_settings)
            .and_return(analysis: {})
        allow(indices)
            .to receive(:exists_alias)
            .with(name: index_alias_name)
            .and_return(false)
        allow(indices)
            .to receive(:exists)
            .with(index: index_alias_name)
            .and_return(false)

        allow(logger).to receive(:warn)
        allow(logger).to receive(:info)
        allow(logger).to receive(:error)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    describe ".reindex" do
        # reindex 開始時と alias 切り替え時に参照する現在の alias 接続先を設定する。
        def expect_reindex_alias_lookup(*physical_names, count:)
            expect(indices)
                .to receive(:get_alias)
                .with(name: index_alias_name)
                .exactly(count).times
                .and_return(alias_response_for(*physical_names))
        end

        # alias が存在しない状態を reindex の alias 参照結果として設定する。
        def expect_missing_reindex_alias(count:)
            expect(indices)
                .to receive(:get_alias)
                .with(name: index_alias_name)
                .exactly(count).times
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)
        end

        it "bulk 投入成功時は alias を切り替えて成功結果を設定する" do
            result = build_reindex_result
            created_index = nil
            block_index = nil
            alias_actions = nil

            allow(indices)
                .to receive(:exists)
                .with(index: index_alias_name)
                .and_return(false)

            allow(indices)
                .to receive(:create) do |args|
                    created_index = args[:index]
                    expect(args[:body]).to eq(
                        settings: index_settings,
                        mappings: mappings,
                    )

                    {
                        "index"               => created_index,
                        "acknowledged"        => true,
                        "shards_acknowledged" => true,
                    }
                end

            expect_reindex_alias_lookup(
                "test__articles__default__2023_12_01_00_00_00_000000",
                count: 2,
            )

            expect(indices)
                .to receive(:update_aliases) do |args|
                    alias_actions = args[:body][:actions]

                    {
                        "acknowledged" => true,
                        "errors"       => false,
                    }
                end

            described_class.reindex(
                index_alias_name,
                index_settings,
                mappings,
                "reindex",
                result,
            ) do |physical_index|
                block_index = physical_index
                true
            end

            expect(block_index).to eq(created_index)
            expect(created_index).to match(
                /\Atest__articles__default__\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}_\d{6}\z/,
            )
            expect(alias_actions).to eq([
                {
                    remove: {
                        index: "test__articles__default__2023_12_01_00_00_00_000000",
                        alias: index_alias_name,
                    },
                },
                {
                    add: {
                        index: created_index,
                        alias: index_alias_name,
                    },
                },
            ])
            expect(result).to eq(
                result:      :success,
                message:     '',
                failed_ids:  [],
                stop_phase:  nil,
                done_phases: [
                    :lock_index,
                    :acquire_index_target_sync_lock,
                    :create_new_index,
                    :index_to_new_index,
                    :switch_alias,
                ],
            )
            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "bulk 投入に失敗した場合は alias を切り替えず停止段階を残す" do
            result = build_reindex_result
            created_index = nil

            expect_missing_reindex_alias(count: 1)

            allow(indices)
                .to receive(:create) do |args|
                    created_index = args[:index]

                    {
                        "index"               => created_index,
                        "acknowledged"        => true,
                        "shards_acknowledged" => true,
                    }
                end

            expect(indices).not_to receive(:update_aliases)

            described_class.reindex(
                index_alias_name,
                index_settings,
                mappings,
                "reindex",
                result,
            ) do |physical_index|
                expect(physical_index).to eq(created_index)
                result[:failed_ids] = ["1", "2"]
                false
            end

            expect(result).to eq(
                result:      :not_success,
                message:     "bulk 投入に失敗した ID があるため alias を切り替えませんでした",
                failed_ids:  ["1", "2"],
                stop_phase:  :index_to_new_index,
                done_phases: [
                    :lock_index,
                    :acquire_index_target_sync_lock,
                    :create_new_index,
                ],
            )
            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "alias 名と同名の物理 index が存在する場合は reindex を開始しない" do
            result = build_reindex_result

            allow(indices)
                .to receive(:exists)
                .with(index: index_alias_name)
                .and_return(true)

            expect(indices).not_to receive(:get_alias)
            expect(indices).not_to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.reindex(
                    index_alias_name,
                    index_settings,
                    mappings,
                    "reindex",
                    result,
                ) do
                    true
                end
            end.to raise_error(
                ArgumentError,
                "エイリアス名と同名の物理インデックスが存在します #{index_alias_name}",
            )

            expect(result).to eq(build_reindex_result)
            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "alias 接続先が AreSearch の物理 index 形式でなければ reindex を開始しない" do
            result = build_reindex_result

            expect_reindex_alias_lookup(
                "external_articles_index",
                count: 1,
            )
            expect(indices).not_to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.reindex(
                    index_alias_name,
                    index_settings,
                    mappings,
                    "reindex",
                    result,
                ) do
                    true
                end
            end.to raise_error(ArgumentError, "不正な物理 index 名です")

            expect(result).to eq(build_reindex_result)
            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "alias 更新APIがaction失敗を返した場合は結果へ残す" do
            result = build_reindex_result

            allow(indices)
                .to receive(:exists)
                .with(index: index_alias_name)
                .and_return(false)
            allow(indices).to receive(:create) do |args|
                {
                    "index"               => args[:index],
                    "acknowledged"        => true,
                    "shards_acknowledged" => true,
                }
            end
            expect_missing_reindex_alias(count: 2)
            allow(indices)
                .to receive(:update_aliases)
                .and_return(
                    "acknowledged" => true,
                    "errors"       => true,
                    "action_results" => [],
                )

            described_class.reindex(
                index_alias_name,
                index_settings,
                mappings,
                "reindex",
                result,
            ) do
                true
            end

            expect(result[:result]).to eq(:not_success)
            expect(result[:message]).to eq("インデックスの切り替えに失敗しました。")
            expect(result[:stop_phase]).to eq(:switch_alias)
            expect(result[:done_phases]).to eq([
                :lock_index,
                :acquire_index_target_sync_lock,
                :create_new_index,
                :index_to_new_index,
            ])
            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "処理中に例外が出た場合も sync lock を削除して例外を再送出する" do
            result = build_reindex_result

            expect_missing_reindex_alias(count: 1)
            allow(indices).to receive(:create) do |args|
                {
                    "index"               => args[:index],
                    "acknowledged"        => true,
                    "shards_acknowledged" => true,
                }
            end
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.reindex(
                    index_alias_name,
                    index_settings,
                    mappings,
                    "reindex",
                    result,
                ) do
                    raise "bulk failed"
                end
            end.to raise_error(RuntimeError, "bulk failed")

            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "alias 更新APIで例外が出た場合も sync lock を削除して再送出する" do
            result = build_reindex_result

            allow(indices)
                .to receive(:exists)
                .with(index: index_alias_name)
                .and_return(false)
            allow(indices).to receive(:create) do |args|
                {
                    "index"               => args[:index],
                    "acknowledged"        => true,
                    "shards_acknowledged" => true,
                }
            end
            expect_missing_reindex_alias(count: 2)
            allow(indices)
                .to receive(:update_aliases)
                .and_raise(RuntimeError, "alias failed")

            expect do
                described_class.reindex(
                    index_alias_name,
                    index_settings,
                    mappings,
                    "reindex",
                    result,
                ) do
                    true
                end
            end.to raise_error(RuntimeError, "alias failed")

            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "処理中の例外後に sync lock 削除も失敗した場合は削除失敗例外を出す" do
            result = build_reindex_result

            expect_missing_reindex_alias(count: 1)
            allow(indices).to receive(:create) do |args|
                {
                    "index"               => args[:index],
                    "acknowledged"        => true,
                    "shards_acknowledged" => true,
                }
            end
            expect(indices).not_to receive(:update_aliases)

            allow(AreSearch::SyncLock)
                .to receive(:where)
                .and_call_original

            allow(AreSearch::SyncLock)
                .to receive(:where)
                .with(
                    id:          kind_of(Integer),
                    owner_token: kind_of(String),
                )
                .and_raise(RuntimeError, "sync lock delete failed")

            raised_error = nil

            begin
                described_class.reindex(
                    index_alias_name,
                    index_settings,
                    mappings,
                    "reindex",
                    result,
                ) do
                    raise "bulk failed"
                end
            rescue RuntimeError => e
                raised_error = e
            end

            expect(raised_error.message).to eq("sync lock delete failed")
            expect(raised_error.cause.message).to eq("bulk failed")
        end

        it "sync lock が残っている場合は未実行結果を設定する" do
            result = build_reindex_result
            create_sync_lock(index_alias_name)

            expect_missing_reindex_alias(count: 1)
            expect(indices).not_to receive(:create)
            expect(indices).not_to receive(:update_aliases)

            described_class.reindex(
                index_alias_name,
                index_settings,
                mappings,
                "reindex",
                result,
            ) do
                true
            end

            expect(result).to eq(
                result:      :not_success,
                message:     "同期ロックを取得できませんでした",
                failed_ids:  [],
                stop_phase:  :acquire_index_target_sync_lock,
                done_phases: [:lock_index],
            )
            expect(AreSearch::SyncLock.index_target_locked?(index_alias_name)).to eq(true)
        end

        it "flock を取得できない場合は未実行結果を設定する" do
            result = build_reindex_result
            expect_missing_reindex_alias(count: 1)
            lock_path = AreSearch.index_lock_file_path(index_alias_name)
            FileUtils.mkdir_p(File.dirname(lock_path))

            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)
                expect(locked).to eq(0)

                described_class.reindex(
                    index_alias_name,
                    index_settings,
                    mappings,
                    "reindex",
                    result,
                ) do
                    true
                end
            end

            expect(result).to eq(
                result:      :not_success,
                message:     "別の処理が実行中のためスキップしました",
                failed_ids:  [],
                stop_phase:  :lock_index,
                done_phases: [],
            )
        end
    end

end

RSpec.describe AreSearch::IndexManager do
    let(:index_alias_name) { "test__articles__default" }
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
        response = {}

        physical_names.each do |physical_name|
            response[physical_name] = {
                "aliases" => {
                    index_alias_name => {},
                },
            }
        end

        response
    end

    def create_sync_lock(index_alias_name, operation: "reindex", message: nil)
        AreSearch::SyncLock.create!(
            index_alias_name: index_alias_name,
            sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            operation:        operation,
            owner_token:   SecureRandom.uuid,
            owner_host:    "test-host",
            owner_pid:     12345,
            started_at:    Time.zone.now,
            message:       message,
        )
    end

    def build_reindex_result
        {
            result: :not_success,
            message: '',
            failed_ids: [],
            stop_phase: nil,
            done_phases: [],
        }
    end

    before do
        AreSearch.index_operation_enabled = true

        allow(AreSearch).to receive(:client).and_return(client)
        allow(AreSearch)
            .to receive(:analyzer_settings)
            .and_return(analysis: {})
        allow(indices)
            .to receive(:exists_alias)
            .with(name: index_alias_name)
            .and_return(false)

        allow(logger).to receive(:warn)
        allow(logger).to receive(:info)
        allow(logger).to receive(:error)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    describe ".index_clean_up" do
        it "削除中に例外が出た場合も sync lock を削除して例外を再送出する" do
            allow(indices)
                .to receive(:get_alias)
                .with(name: index_alias_name)
                .and_return(
                    alias_response_for(
                        "test__articles__default__2024_01_02_00_00_00_000000",
                    ),
                )

            allow(indices)
                .to receive(:get)
                .with(index: "#{index_alias_name}__*")
                .and_return(
                    {
                        "test__articles__default__2024_01_01_00_00_00_000000" => {},
                        "test__articles__default__2024_01_02_00_00_00_000000" => {},
                    },
                )

            allow(indices)
                .to receive(:delete)
                .with(
                    index: "test__articles__default__2024_01_01_00_00_00_000000",
                )
                .and_raise(RuntimeError, "delete failed")

            expect do
                described_class.index_clean_up(index_alias_name)
            end.to raise_error(RuntimeError, "delete failed")

            expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
        end

        it "sync lock が残っている場合は未実行結果を返す" do
            create_sync_lock(index_alias_name, operation: "clean_up")

            expect(indices).not_to receive(:get_alias)
            expect(indices).not_to receive(:get)
            expect(indices).not_to receive(:delete)

            result = described_class.index_clean_up(index_alias_name)

            expect(result).to eq(
                result:             :not_success,
                message:            "同期ロックを取得できませんでした",
                stop_phase:         :acquire_index_target_sync_lock,
                done_phases:        [:lock_index],
                delete_index_names: [],
            )
            expect(AreSearch::SyncLock.index_target_locked?(index_alias_name)).to eq(true)
        end
    end

    describe ".delete_physical_index!" do
        it "指定された物理 index を削除する" do
            expect(indices)
                .to receive(:delete)
                .with(
                    index: "test__articles__default__2024_01_01_00_00_00_000000",
                )
                .and_return("acknowledged" => true)

            described_class.delete_physical_index!(
                "test__articles__default__2024_01_01_00_00_00_000000",
            )
        end
    end
end
