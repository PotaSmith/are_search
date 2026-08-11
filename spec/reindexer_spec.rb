# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::Reindexer do
    let(:mappings) do
        {
            properties: {
                id:    { type: "long" },
                title: { type: "text" },
            },
        }
    end

    let(:mappings_for_index) do
        {
            properties: {
                id:    { type: "long" },
                title: { type: "text" },
                are_search_reserved_ar_model_class_name: AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAME_SETTING,
                are_search_reserved_ar_instance_key:     AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAME_SETTING,
            },
        }
    end

    let(:index_settings) do
        { max_result_window: 50_000 }
    end

    let(:sync_stage_name) do
        "default"
    end

    let(:record_count) do
        0
    end

    let(:model) do
        class_double(
            "Article",
            count:      record_count,
            superclass: nil,
        )
    end

    let(:index_target) do
        target = AreSearch::IndexTarget.allocate

        allow(target)
            .to receive(:model_class)
            .and_return(model)
        allow(target)
            .to receive(:index_target_name)
            .and_return(:default)
        allow(target)
            .to receive(:are_search_index_alias_name)
            .and_return("test__articles__default")
        allow(target)
            .to receive(:are_search_index_mappings)
            .and_return(mappings)
        allow(target)
            .to receive(:are_search_index_mappings_for_index)
            .and_return(mappings_for_index)
        allow(target)
            .to receive(:are_search_index_settings)
            .and_return(index_settings)

        target
    end

    let(:client) do
        instance_double("Elasticsearch::Client")
    end

    let(:progress_bar_class) do
        Class.new do
            attr_reader :increments

            def initialize(_total)
                @increments = []
            end

            def increment!(size)
                @increments << size
            end
        end
    end

    def run_index_manager_block(result, physical_index_name, &block)
        result[:stop_phase] = :index_to_new_index

        if block.call(physical_index_name)
            result[:result] = :success
            result[:stop_phase] = nil
            result[:done_phases] = [
                :lock_index,
                :create_marker,
                :create_new_index,
                :index_to_new_index,
                :switch_alias,
            ]
        else
            result[:message] =
                "bulk 投入に失敗した ID があるため alias を切り替えませんでした"
            result[:done_phases] = [
                :lock_index,
                :create_marker,
                :create_new_index,
            ]
        end
    end

    before do
        allow(AreSearch).to receive(:client).and_return(client)
        stub_const("ProgressBar", progress_bar_class)

        allow(model)
            .to receive(:are_search_get_all_sync_stage_names)
            .with(:default)
            .and_return([sync_stage_name])

        logger = instance_double("Logger", error: nil)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    describe ".reindex_index_target" do
        it "IndexTarget以外は拒否する" do
            expect(AreSearch::IndexManager)
                .not_to receive(:reindex)

            expect do
                described_class.reindex_index_target(
                    Object.new,
                    sync_stage_name,
                )
            end.to raise_error(
                ArgumentError,
                "index_target は AreSearch::IndexTarget を指定してください",
            )
        end

        it "Searchable を継承した子クラスのIndexTargetを直接渡した場合は拒否する" do
            searchable_parent = double("searchable_parent")
            allow(searchable_parent)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            child_model_class = double(
                "SpecialArticle",
                name:       "SpecialArticle",
                superclass: searchable_parent,
            )
            child_index_target = AreSearch::IndexTarget.allocate
            allow(child_index_target)
                .to receive(:model_class)
                .and_return(child_model_class)

            expect(AreSearch::IndexManager)
                .not_to receive(:reindex)

            expect do
                described_class.reindex_index_target(
                    child_index_target,
                    sync_stage_name,
                )
            end.to raise_error(
                AreSearch::Error,
                "Searchable を継承した子クラスから reindex は実行できません: SpecialArticle",
            )
        end

        it "IndexTargetに存在しないstageは拒否する" do
            allow(model)
                .to receive(:are_search_get_all_sync_stage_names)
                .with(:default)
                .and_return(["other"])

            expect(AreSearch::IndexManager)
                .not_to receive(:reindex)

            expect do
                described_class.reindex_index_target(
                    index_target,
                    sync_stage_name,
                )
            end.to raise_error(
                ArgumentError,
                "sync_stage_name が IndexTarget に定義されていません: default",
            )
        end

        context "when all bulk requests succeed" do
            let(:record_count) do
                2
            end

            it "IndexManagerへ結果Hashを渡し、生成された物理indexへbulk投入する" do
                first_record = instance_double("Article", id: 1)
                second_record = instance_double("Article", id: 2)

                expect(first_record)
                    .to receive(:are_search_indexable?)
                    .with(:default, sync_stage_name)
                    .and_return(true)

                expect(first_record)
                    .to receive(:are_search_index_data_for_index!)
                    .with(index_target, sync_stage_name)
                    .and_return(id: 1, title: "first")

                expect(second_record)
                    .to receive(:are_search_indexable?)
                    .with(:default, sync_stage_name)
                    .and_return(true)

                expect(second_record)
                    .to receive(:are_search_index_data_for_index!)
                    .with(index_target, sync_stage_name)
                    .and_return(id: 2, title: "second")

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                end

                expected_body = [
                    { index: { _index: "test_articles__20240101120000", _id: "1" } },
                    { id: 1, title: "first" },
                    { index: { _index: "test_articles__20240101120000", _id: "2" } },
                    { id: 2, title: "second" },
                ]

                expect(AreSearch::IndexManager)
                    .to receive(:reindex) do |index_alias_name, actual_index_settings, index_mappings, operation, result, &block|
                        expect(index_alias_name).to eq("test__articles__default")
                        expect(actual_index_settings).to eq(index_settings)
                        expect(index_mappings).to eq(mappings_for_index)
                        expect(operation).to eq("reindex")
                        expect(result).to eq(
                            result:      :not_success,
                            message:     '',
                            failed_ids:  [],
                            stop_phase:  nil,
                            done_phases: [],
                        )

                        run_index_manager_block(
                            result,
                            "test_articles__20240101120000",
                            &block
                        )
                    end

                expect(client)
                    .to receive(:bulk)
                    .with(body: expected_body)
                    .and_return(
                        "errors" => false,
                        "items"  => [
                            { "index" => { "_id" => "1" } },
                            { "index" => { "_id" => "2" } },
                        ],
                    )

                result = described_class.reindex_index_target(
                    index_target,
                    sync_stage_name,
                )

                expect(result).to eq(
                    result:      :success,
                    message:     '',
                    failed_ids:  [],
                    stop_phase:  nil,
                    done_phases: [
                        :lock_index,
                        :create_marker,
                        :create_new_index,
                        :index_to_new_index,
                                :switch_alias,
                    ],
                )
            end
        end

        context "when Elasticsearch reports item errors" do
            let(:record_count) do
                2
            end

            it "失敗IDをモデルのID型のまま結果Hashへ残す" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 2, title: "second" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                end

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _index_mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__20240101120000",
                            &block
                        )
                    end

                response = {
                    "errors" => true,
                    "items"  => [
                        {
                            "index" => {
                                "_id" => "1",
                            },
                        },
                        {
                            "index" => {
                                "_id"   => "2",
                                "error" => { "type" => "mapper_parsing_exception" },
                            },
                        },
                    ],
                }

                allow(client).to receive(:bulk).and_return(response)

                result = described_class.reindex_index_target(
                    index_target,
                    sync_stage_name,
                )

                expect(result).to eq(
                    result:      :not_success,
                    message:     "bulk 投入に失敗した ID があるため alias を切り替えませんでした",
                    failed_ids:  [2],
                    stop_phase:  :index_to_new_index,
                    done_phases: [
                        :lock_index,
                        :create_marker,
                        :create_new_index,
                    ],
                )
            end
        end

        context "when bulk response does not match the request" do
            let(:record_count) do
                1
            end

            it "items件数が送信件数と一致しなければ例外にする" do
                record = instance_double(
                    "Article",
                    id: 1,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 1, title: "first" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([record])
                end

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _index_mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__20240101120000",
                            &block
                        )
                    end

                allow(client)
                    .to receive(:bulk)
                    .and_return("errors" => false, "items" => [])

                expect do
                    described_class.reindex_index_target(
                        index_target,
                        sync_stage_name,
                    )
                end.to raise_error(
                    AreSearch::Error,
                    "Elasticsearch bulk response の件数が一致しません",
                )
            end
        end

        context "when some records are not indexable" do
            let(:record_count) do
                2
            end

            it "index対象外レコードをbulk bodyへ追加しない" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_indexable?: false,
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                end

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _index_mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__20240101120000",
                            &block
                        )
                    end

                expect(client)
                    .to receive(:bulk)
                    .with(
                        body: [
                            { index: { _index: "test_articles__20240101120000", _id: "1" } },
                            { id: 1, title: "first" },
                        ],
                    )
                    .and_return(
                        "errors" => false,
                        "items"  => [
                            { "index" => { "_id" => "1" } },
                        ],
                    )

                result = described_class.reindex_index_target(
                    index_target,
                    sync_stage_name,
                )

                expect(result[:result]).to eq(:success)
                expect(result[:failed_ids]).to eq([])
            end
        end

        context "when multiple batches are processed" do
            let(:record_count) do
                3
            end

            it "batchごとにbulkを呼ぶ" do
                first_record = instance_double(
                    "Article",
                    id: 1,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 1, title: "first" },
                )
                second_record = instance_double(
                    "Article",
                    id: 2,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 2, title: "second" },
                )
                third_record = instance_double(
                    "Article",
                    id: 3,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 3, title: "third" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([first_record, second_record])
                    block.call([third_record])
                end

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _index_mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__20240101120000",
                            &block
                        )
                    end

                expect(client)
                    .to receive(:bulk)
                    .with(
                        body: [
                            { index: { _index: "test_articles__20240101120000", _id: "1" } },
                            { id: 1, title: "first" },
                            { index: { _index: "test_articles__20240101120000", _id: "2" } },
                            { id: 2, title: "second" },
                        ],
                    )
                    .and_return(
                        "errors" => false,
                        "items"  => [
                            { "index" => { "_id" => "1" } },
                            { "index" => { "_id" => "2" } },
                        ],
                    )

                expect(client)
                    .to receive(:bulk)
                    .with(
                        body: [
                            { index: { _index: "test_articles__20240101120000", _id: "3" } },
                            { id: 3, title: "third" },
                        ],
                    )
                    .and_return(
                        "errors" => false,
                        "items"  => [
                            { "index" => { "_id" => "3" } },
                        ],
                    )

                result = described_class.reindex_index_target(
                    index_target,
                    sync_stage_name,
                )

                expect(result[:result]).to eq(:success)
            end
        end

        context "when bulk raises" do
            let(:record_count) do
                1
            end

            it "例外を握りつぶさない" do
                record = instance_double(
                    "Article",
                    id: 1,
                    are_search_indexable?: true,
                    are_search_index_data_for_index!: { id: 1, title: "first" },
                )

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([record])
                end

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__2024_01_01_00_00_00_000000",
                            &block
                        )
                    end

                allow(client)
                    .to receive(:bulk)
                    .and_raise(RuntimeError, "bulk failed")

                expect do
                    described_class.reindex_index_target(
                        index_target,
                        sync_stage_name,
                    )
                end.to raise_error(RuntimeError, "bulk failed")
            end
        end

        context "when data for index raises" do
            let(:record_count) do
                1
            end

            it "例外を握りつぶさずbulkしない" do
                record = instance_double(
                    "Article",
                    id: 1,
                    are_search_indexable?: true,
                )

                allow(record)
                    .to receive(:are_search_index_data_for_index!)
                    .with(index_target, sync_stage_name)
                    .and_raise(AreSearch::Error, "reserved field")

                allow(model).to receive(:find_in_batches) do |batch_size:, &block|
                    expect(batch_size).to eq(500)
                    block.call([record])
                end

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__2024_01_01_00_00_00_000000",
                            &block
                        )
                    end

                expect(client).not_to receive(:bulk)

                expect do
                    described_class.reindex_index_target(
                        index_target,
                        sync_stage_name,
                    )
                end.to raise_error(AreSearch::Error, "reserved field")
            end
        end

        context "when the model has no records" do
            let(:record_count) do
                0
            end

            it "ProgressBarとbulkを使わず成功結果を返す" do
                allow(model).to receive(:find_in_batches)

                allow(AreSearch::IndexManager)
                    .to receive(:reindex) do |_index_name, _index_settings, _index_mappings, _operation, result, &block|
                        run_index_manager_block(
                            result,
                            "test_articles__20240101120000",
                            &block
                        )
                    end

                expect(ProgressBar).not_to receive(:new)
                expect(client).not_to receive(:bulk)

                result = described_class.reindex_index_target(
                    index_target,
                    sync_stage_name,
                )

                expect(result[:result]).to eq(:success)
                expect(result[:failed_ids]).to eq([])
            end
        end
    end
end
