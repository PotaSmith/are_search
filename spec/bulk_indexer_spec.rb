# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::BulkIndexer do
    let(:model_class) do
        double("model_class")
    end

    let(:index_target) do
        target = AreSearch::IndexTarget.allocate

        allow(target)
            .to receive(:model_class)
            .and_return(model_class)
        allow(target)
            .to receive(:index_target_name)
            .and_return(:default)
        allow(target)
            .to receive(:are_search_index_alias_name)
            .and_return("test__articles__default")
        allow(target)
            .to receive(:are_search_index_alias_exists?)
            .and_return(true)

        target
    end

    let(:sync_stage_name) do
        "default"
    end

    let(:result_dir) do
        @result_dir
    end

    let(:indexer) do
        described_class.new(
            index_target,
            sync_stage_name,
            result_dir:      result_dir,
            max_bulk_bytes:  10_000,
            max_bulk_count:  10,
            max_fail_count:  10,
        )
    end

    around do |example|
        Dir.mktmpdir("are_search_bulk_indexer") do |dir|
            @result_dir = dir
            example.run
        end
    end

    before do
        allow(model_class)
            .to receive(:are_search_get_all_sync_stage_names)
            .with(:default)
            .and_return([sync_stage_name])
    end

    # 指定したレコードをrelationのfind_eachから順番に返す。
    def allow_find_each(relation, records)
        allow(relation).to receive(:find_each) do |&block|
            records.each do |record|
                block.call(record)
            end
        end
    end

    # BulkIndexerの結果ファイルへ書ける固定形式の1行を返す。
    def result_line(id, result)
        "[2026-08-07T12:00:00.000000+09:00] #{id} #{result}\n"
    end

    describe "#bulk_index_index_target" do
        it "dataとrecoverディレクトリを作成して全件relationを処理する" do
            relation = double("relation")

            expect(model_class)
                .to receive(:all)
                .and_return(relation)
            expect(relation)
                .to receive(:find_each)

            indexer.bulk_index_index_target

            expect(File.directory?(File.join(result_dir, "data"))).to eq(true)
            expect(File.directory?(File.join(result_dir, "recover"))).to eq(true)
        end

        it "成功、bulk失敗、data_skip、data_failを記録し最後の処理IDをcheckpointへ記録する" do
            relation = double("relation")
            success_record = double("success_record", id: 1)
            bulk_failure_record = double("bulk_failure_record", id: 2)
            skip_record = double("skip_record", id: 3)
            data_failure_record = double("data_failure_record", id: 4)

            allow(model_class)
                .to receive(:all)
                .and_return(relation)
            allow_find_each(
                relation,
                [
                    success_record,
                    bulk_failure_record,
                    skip_record,
                    data_failure_record,
                ],
            )

            allow(success_record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(true)
            allow(success_record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, sync_stage_name)
                .and_return(id: 1, title: "success")

            allow(bulk_failure_record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(true)
            allow(bulk_failure_record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, sync_stage_name)
                .and_return(id: 2, title: "failure")

            allow(skip_record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(false)
            expect(skip_record)
                .not_to receive(:are_search_index_data_for_index!)

            allow(data_failure_record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(true)
            allow(data_failure_record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, sync_stage_name)
                .and_raise(RuntimeError, "data build failed\nsecond line")

            expect(AreSearch::EsAdapter)
                .to receive(:no_validation_bulk) do |body:|
                    body_lines = body.lines.map do |line|
                        JSON.parse(line)
                    end

                    expect(body_lines).to eq([
                        {
                            "index" => {
                                "_index" => "test__articles__default",
                                "_id"    => "1",
                            },
                        },
                        {
                            "id"    => 1,
                            "title" => "success",
                        },
                        {
                            "index" => {
                                "_index" => "test__articles__default",
                                "_id"    => "2",
                            },
                        },
                        {
                            "id"    => 2,
                            "title" => "failure",
                        },
                    ])

                    {
                        "items" => [
                            {
                                "index" => {
                                    "_id" => "1",
                                },
                            },
                            {
                                "index" => {
                                    "_id"   => "2",
                                    "error" => {
                                        "type" => "mapper_parsing_exception",
                                    },
                                },
                            },
                        ],
                    }
                end

            indexer.bulk_index_index_target

            data_dir = File.join(result_dir, "data")

            expect(File.read(File.join(data_dir, "bulk_success.log"))).to match(
                /\A\[[^\]]+\] 1 success\n\z/,
            )
            expect(File.read(File.join(data_dir, "bulk_failure.log"))).to match(
                /\A\[[^\]]+\] 2 fail\n\z/,
            )
            expect(File.read(File.join(data_dir, "data_skip.log"))).to match(
                /\A\[[^\]]+\] 3 data_skip\n\z/,
            )
            expect(File.read(File.join(data_dir, "data_fail.log"))).to match(
                /\A\[[^\]]+\] 4 data_fail\n\z/,
            )
            expect(File.read(File.join(data_dir, "check_point.log"))).to match(
                /\A\[[^\]]+\] 4 check_point\n\z/,
            )

            bulk_log = File.read(File.join(result_dir, "bulk.log"))
            expect(bulk_log).to match(/\[[^\]]+\] 1 success/)
            expect(bulk_log).to match(/\[[^\]]+\] 2 .*mapper_parsing_exception.* fail/)
            expect(bulk_log).to match(/\[[^\]]+\] 3 data_skip/)
            expect(bulk_log).to match(
                /\[[^\]]+\] 4 RuntimeError: data build failed second line data_fail/,
            )
            expect(bulk_log).not_to include("check_point")
        end

        it "checkpointの最後のIDより後だけを再開対象にする" do
            data_dir = File.join(result_dir, "data")
            FileUtils.mkdir_p(data_dir)

            File.write(
                File.join(data_dir, "check_point.log"),
                result_line("12", "check_point"),
            )
            File.write(
                File.join(data_dir, "bulk_success.log"),
                result_line("100", "success"),
            )
            File.write(
                File.join(data_dir, "bulk_failure.log"),
                result_line("101", "fail"),
            )

            relation = double("relation")

            expect(model_class)
                .to receive(:where)
                .with("id > ?", "12")
                .and_return(relation)
            expect(relation)
                .to receive(:find_each)

            indexer.bulk_index_index_target
        end

        it "checkpointが無ければ全件を対象にする" do
            relation = double("relation")

            expect(model_class)
                .to receive(:all)
                .and_return(relation)
            expect(model_class)
                .not_to receive(:where)
            expect(relation)
                .to receive(:find_each)

            indexer.bulk_index_index_target
        end

        it "空白を含むIDは処理を開始せず拒否する" do
            relation = double("relation")
            record = double("record", id: "invalid id")

            allow(model_class)
                .to receive(:all)
                .and_return(relation)
            allow_find_each(relation, [record])

            expect(AreSearch::EsAdapter)
                .not_to receive(:no_validation_bulk)

            expect do
                indexer.bulk_index_index_target
            end.to raise_error(
                AreSearch::Error,
                /bulk結果ファイルへ記録できないIDです/,
            )
        end

        it "bulk APIの例外時はcheckpointを進めず例外を伝播する" do
            relation = double("relation")
            record = double("record", id: 1)

            allow(model_class)
                .to receive(:all)
                .and_return(relation)
            allow_find_each(relation, [record])
            allow(record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(true)
            allow(record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, sync_stage_name)
                .and_return(id: 1)

            allow(AreSearch::EsAdapter)
                .to receive(:no_validation_bulk)
                .and_raise(RuntimeError, "bulk failed")

            expect do
                indexer.bulk_index_index_target
            end.to raise_error(RuntimeError, "bulk failed")

            expect(
                File.exist?(File.join(result_dir, "data", "check_point.log")),
            ).to eq(false)
        end

        it "are_search_indexable?の例外はdata_failとして記録して処理を継続する" do
            relation = double("relation")
            failed_record = double("failed_record", id: 1)
            success_record = double("success_record", id: 2)

            allow(model_class)
                .to receive(:all)
                .and_return(relation)
            allow_find_each(relation, [failed_record, success_record])

            allow(failed_record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_raise(RuntimeError, "indexable failed")

            allow(success_record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(true)
            allow(success_record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, sync_stage_name)
                .and_return(id: 2)

            expect(AreSearch::EsAdapter)
                .to receive(:no_validation_bulk)
                .and_return(
                    "items" => [
                        {
                            "index" => {
                                "_id" => "2",
                            },
                        },
                    ],
                )

            indexer.bulk_index_index_target

            data_dir = File.join(result_dir, "data")
            expect(File.read(File.join(data_dir, "data_fail.log"))).to match(
                /\A\[[^\]]+\] 1 data_fail\n\z/,
            )
            expect(File.read(File.join(data_dir, "bulk_success.log"))).to match(
                /\A\[[^\]]+\] 2 success\n\z/,
            )
            expect(File.read(File.join(data_dir, "check_point.log"))).to match(
                /\[[^\]]+\] 2 check_point\n\z/,
            )
        end

    end

    describe "#bulk_recover_index_target" do
        it "recoverではcheckpointを記録しない" do
            data_dir = File.join(result_dir, "data")
            lookup_relation = double("lookup_relation")
            relation = double("relation")
            record = double("record", id: 1)

            FileUtils.mkdir_p(data_dir)
            File.write(
                File.join(data_dir, "bulk_failure.log"),
                result_line("1", "fail"),
            )

            expect(model_class)
                .to receive(:where)
                .with(id: ["1"])
                .ordered
                .and_return(lookup_relation)
            expect(lookup_relation)
                .to receive(:pluck)
                .with(:id)
                .and_return([1])
            expect(model_class)
                .to receive(:where)
                .with(id: ["1"])
                .ordered
                .and_return(relation)
            allow_find_each(relation, [record])

            allow(record)
                .to receive(:are_search_indexable?)
                .with(:default, sync_stage_name)
                .and_return(true)
            allow(record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, sync_stage_name)
                .and_return(id: 1)

            expect(AreSearch::EsAdapter)
                .to receive(:no_validation_bulk)
                .and_return(
                    "items" => [
                        {
                            "index" => {
                                "_id" => "1",
                            },
                        },
                    ],
                )

            indexer.bulk_recover_index_target

            recover_dir = File.join(result_dir, "recover")
            expect(
                File.exist?(File.join(recover_dir, "check_point.log")),
            ).to eq(false)
            expect(
                File.exist?(File.join(recover_dir, "recover_check_point.log")),
            ).to eq(false)
        end

        it "通常実行の失敗IDからrecover済みIDを除いて処理する" do
            data_dir = File.join(result_dir, "data")
            recover_dir = File.join(result_dir, "recover")
            FileUtils.mkdir_p(data_dir)
            FileUtils.mkdir_p(recover_dir)

            File.write(
                File.join(data_dir, "bulk_failure.log"),
                result_line("2", "fail") + result_line("4", "fail"),
            )
            File.write(
                File.join(data_dir, "data_fail.log"),
                result_line("3", "data_fail"),
            )
            File.write(
                File.join(recover_dir, "recover_bulk_success.log"),
                result_line("2", "success"),
            )

            lookup_relation = double("lookup_relation")
            relation = double("relation")

            expect(model_class)
                .to receive(:where)
                .with(id: ["4", "3"])
                .ordered
                .and_return(lookup_relation)
            expect(lookup_relation)
                .to receive(:pluck)
                .with(:id)
                .and_return([4, 3])
            expect(model_class)
                .to receive(:where)
                .with(id: ["4", "3"])
                .ordered
                .and_return(relation)
            expect(relation)
                .to receive(:find_each)

            indexer.bulk_recover_index_target
        end


        it "同じ失敗IDが複数回記録されてもrecover対象件数は重複しない" do
            data_dir = File.join(result_dir, "data")
            FileUtils.mkdir_p(data_dir)

            failure_file = File.join(data_dir, "bulk_failure.log")
            File.open(failure_file, "w") do |file|
                1001.times do
                    file.write(result_line("1", "fail"))
                end
            end

            lookup_relation = double("lookup_relation")
            relation = double("relation")

            expect(model_class)
                .to receive(:where)
                .with(id: ["1"])
                .ordered
                .and_return(lookup_relation)
            expect(lookup_relation)
                .to receive(:pluck)
                .with(:id)
                .and_return([1])
            expect(model_class)
                .to receive(:where)
                .with(id: ["1"])
                .ordered
                .and_return(relation)
            expect(relation)
                .to receive(:find_each)

            indexer.bulk_recover_index_target
        end

        it "recover対象がDBから削除済みならdata_skipとして処理済みにする" do
            data_dir = File.join(result_dir, "data")
            lookup_relation = double("lookup_relation")
            relation = double("relation")

            FileUtils.mkdir_p(data_dir)
            File.write(
                File.join(data_dir, "bulk_failure.log"),
                result_line("1", "fail"),
            )

            expect(model_class)
                .to receive(:where)
                .with(id: ["1"])
                .ordered
                .and_return(lookup_relation)
            expect(lookup_relation)
                .to receive(:pluck)
                .with(:id)
                .and_return([])
            expect(model_class)
                .to receive(:where)
                .with(id: [])
                .ordered
                .and_return(relation)
            allow_find_each(relation, [])

            indexer.bulk_recover_index_target

            recover_skip_file = File.join(
                result_dir,
                "recover",
                "recover_data_skip.log",
            )
            expect(File.read(recover_skip_file)).to match(
                /\A\[[^\]]+\] 1 data_skip\n\z/,
            )

            expect(model_class)
                .not_to receive(:where)

            expect do
                indexer.bulk_recover_index_target
            end.to raise_error(AreSearch::Error, "recover対象がありません")
        end

        it "recover対象が無ければ拒否する" do
            expect(model_class)
                .not_to receive(:where)

            expect do
                indexer.bulk_recover_index_target
            end.to raise_error(AreSearch::Error, "recover対象がありません")
        end

        it "通常実行の失敗対象IDが上限を超えていれば拒否する" do
            data_dir = File.join(result_dir, "data")
            FileUtils.mkdir_p(data_dir)

            failure_file = File.join(data_dir, "bulk_failure.log")
            File.open(failure_file, "w") do |file|
                2001.times do |index|
                    file.write(result_line(index + 1, "fail"))
                end
            end

            expect(model_class)
                .not_to receive(:where)

            expect do
                indexer.bulk_recover_index_target
            end.to raise_error(
                AreSearch::Error,
                "recover対象が多すぎます: 2001 / 上限 2000",
            )
        end
    end

    describe "引数検査" do
        it "IndexTarget以外は拒否する" do
            invalid_indexer = described_class.new(
                Object.new,
                sync_stage_name,
                result_dir:      result_dir,
                max_bulk_bytes:  100,
                max_bulk_count:  10,
                max_fail_count:  1,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "index_target は AreSearch::IndexTarget を指定してください",
            )
        end

        it "IndexTargetに存在しないstageは拒否する" do
            allow(model_class)
                .to receive(:are_search_get_all_sync_stage_names)
                .with(:default)
                .and_return(["other"])

            expect do
                indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "sync_stage_name が IndexTarget に定義されていません: default",
            )
        end

        it "対象IndexTargetのaliasが存在しなければ拒否する" do
            allow(index_target)
                .to receive(:are_search_index_alias_exists?)
                .and_return(false)

            expect(model_class)
                .not_to receive(:all)
            expect(AreSearch::EsAdapter)
                .not_to receive(:no_validation_bulk)

            expect do
                indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "indexが存在しません test__articles__default",
            )
        end

        it "result_dirがnilなら指定不足として拒否する" do
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      nil,
                max_bulk_bytes:  100,
                max_bulk_count:  10,
                max_fail_count:  1,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(ArgumentError, "result_dir を指定してください")
        end

        it "空のresult_dirは拒否する" do
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      "",
                max_bulk_bytes:  100,
                max_bulk_count:  10,
                max_fail_count:  1,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(ArgumentError, "result_dir を指定してください")
        end

        it "存在しないresult_dirは拒否する" do
            missing_dir = File.join(result_dir, "missing")
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      missing_dir,
                max_bulk_bytes:  100,
                max_bulk_count:  10,
                max_fail_count:  1,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(ArgumentError, "result_dir がありません")
        end

        it "bulk上限値は正のIntegerだけを受け付ける" do
            invalid_values = [0, -1, 1.5, "10"]

            invalid_values.each do |invalid_value|
                invalid_indexer = described_class.new(
                    index_target,
                    sync_stage_name,
                    result_dir:      result_dir,
                    max_bulk_bytes:  invalid_value,
                    max_bulk_count:  10,
                    max_fail_count:  1,
                )

                expect do
                    invalid_indexer.bulk_index_index_target
                end.to raise_error(
                    ArgumentError,
                    "max_bulk_bytes は正の Integer を指定してください",
                )
            end
        end

        it "max_bulk_countは正のIntegerだけを受け付ける" do
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      result_dir,
                max_bulk_bytes:  100,
                max_bulk_count:  0,
                max_fail_count:  1,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "max_bulk_count は正の Integer を指定してください",
            )
        end

        it "max_fail_countは正のIntegerだけを受け付ける" do
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      result_dir,
                max_bulk_bytes:  100,
                max_bulk_count:  10,
                max_fail_count:  0,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "max_fail_count は正の Integer を指定してください",
            )
        end

        it "max_fail_countはrecover上限の半分以下だけを受け付ける" do
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      result_dir,
                max_bulk_bytes:  100,
                max_bulk_count:  10,
                max_fail_count:  1001,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "max_fail_count は 1000 以下で指定してください",
            )
        end

        it "max_bulk_countはmax_fail_count以下だけを受け付ける" do
            invalid_indexer = described_class.new(
                index_target,
                sync_stage_name,
                result_dir:      result_dir,
                max_bulk_bytes:  100,
                max_bulk_count:  11,
                max_fail_count:  10,
            )

            expect do
                invalid_indexer.bulk_index_index_target
            end.to raise_error(
                ArgumentError,
                "max_bulk_count は max_fail_count 以下で指定してください",
            )
        end
    end
end

RSpec.describe AreSearch::IndexTarget, "#are_search_bulk_index" do
    let(:index_target) do
        described_class.allocate
    end

    let(:bulk_indexer) do
        instance_double(AreSearch::BulkIndexer)
    end

    let(:arguments) do
        {
            result_dir:      "/tmp/are_search/sample",
            max_bulk_bytes:  1024,
            max_bulk_count:  5,
            max_fail_count:  5,
        }
    end

    it "通常実行では BulkIndexer#bulk_index_index_target へ委譲する" do
        expect(AreSearch::BulkIndexer)
            .to receive(:new)
            .with(
                index_target,
                "default",
                **arguments,
            )
            .and_return(bulk_indexer)
        expect(bulk_indexer)
            .to receive(:bulk_index_index_target)
            .and_return(:indexed)

        result = index_target.are_search_bulk_index(
            "default",
            **arguments,
        )

        expect(result).to eq(:indexed)
    end

    it "recover指定時は BulkIndexer#bulk_recover_index_target へ委譲する" do
        expect(AreSearch::BulkIndexer)
            .to receive(:new)
            .with(
                index_target,
                "default",
                **arguments,
            )
            .and_return(bulk_indexer)
        expect(bulk_indexer)
            .to receive(:bulk_recover_index_target)
            .and_return(:recovered)

        result = index_target.are_search_bulk_index(
            "default",
            **arguments,
            recover: true,
        )

        expect(result).to eq(:recovered)
    end
end
