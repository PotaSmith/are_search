# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"

RSpec.describe AreSearch::BulkIndexer::Buffer do
    let(:logger) do
        double("logger", fail_count: 0)
    end

    # テスト対象の標準Bufferを返す。
    def build_buffer(
        max_bulk_bytes: 10_000,
        max_bulk_count: 10,
        max_fail_count: 3,
        max_skip_count: 10
    )
        described_class.new(
            max_bulk_bytes: max_bulk_bytes,
            max_bulk_count: max_bulk_count,
            max_fail_count: max_fail_count,
            max_skip_count: max_skip_count,
        )
    end

    # actionとdataをNDJSON化したときのbyte数を返す。
    def serialized_bytesize(action, data)
        action_line = Elasticsearch::API.serializer.dump(action) + "\n"
        data_line = Elasticsearch::API.serializer.dump(data) + "\n"

        action_line.bytesize + data_line.bytesize
    end

    it "sync dataをNDJSONへ変換してkeyとcheckpointを返す" do
        buffer = build_buffer
        action = {
            index: {
                _index: "test__articles__default",
                _id:    "1",
            },
        }
        data = {
            id:    1,
            title: "title",
        }

        buffer.append_sync_data("1", action, data)
        result = buffer.take_all

        expected_body =
            Elasticsearch::API.serializer.dump(action) + "\n" +
            Elasticsearch::API.serializer.dump(data) + "\n"

        expect(result).to eq(
            body:               expected_body,
            keys:               ["1"],
            skip_keys:          [],
            fail_key_and_errors: [],
            check_point_key:    "1",
        )
    end

    it "takeは送信待ちだけを返し保留中の1件を次回へ残す" do
        buffer = build_buffer
        first_action = { index: { _index: "index", _id: "1" } }
        second_action = { index: { _index: "index", _id: "2" } }

        buffer.append_sync_data("1", first_action, { id: 1 })
        buffer.append_sync_data("2", second_action, { id: 2 })

        first_result = buffer.take
        second_result = buffer.take_all

        expect(first_result[:keys]).to eq(["1"])
        expect(first_result[:check_point_key]).to eq("1")
        expect(second_result[:keys]).to eq(["2"])
        expect(second_result[:check_point_key]).to eq("2")
    end

    it "skipとfailはbulk bodyへ入れずcheckpoint対象として返す" do
        buffer = build_buffer
        error = RuntimeError.new("data failed")

        buffer.append_no_sync_data("1", :skip, nil)
        buffer.append_no_sync_data("2", :fail, error)
        result = buffer.take_all

        expect(result).to eq(
            body:               "",
            keys:               [],
            skip_keys:          ["1"],
            fail_key_and_errors: [["2", error]],
            check_point_key:    "2",
        )
    end

    it "append_no_sync_dataはfailとskip以外を拒否する" do
        buffer = build_buffer

        expect do
            buffer.append_no_sync_data("1", :index, nil)
        end.to raise_error(AreSearch::Error, "不正な内部操作です")
    end

    it "append_sync_dataはfailとskipをactionとして受け付けない" do
        buffer = build_buffer

        expect do
            buffer.append_sync_data("1", :fail, {})
        end.to raise_error(AreSearch::Error, "不正な内部操作です")
    end

    it "serializerで例外が出たsync dataはdata failとして保持する" do
        buffer = build_buffer
        serializer = double("serializer")
        action = { index: { _index: "index", _id: "1" } }
        error = RuntimeError.new("serialize failed")

        allow(Elasticsearch::API)
            .to receive(:serializer)
            .and_return(serializer)
        allow(serializer)
            .to receive(:dump)
            .with(action)
            .and_raise(error)

        buffer.append_sync_data("1", action, { id: 1 })
        result = buffer.take_all

        expect(result[:body]).to eq("")
        expect(result[:keys]).to eq([])
        expect(result[:fail_key_and_errors]).to eq([["1", error]])
        expect(result[:check_point_key]).to eq("1")
    end

    it "1件だけでmax_bulk_bytesを超えるsync dataはdata failとして保持する" do
        buffer = build_buffer(max_bulk_bytes: 1)

        buffer.append_sync_data(
            "1",
            { index: { _index: "index", _id: "1" } },
            { id: 1 },
        )
        result = buffer.take_all

        expect(result[:body]).to eq("")
        expect(result[:keys]).to eq([])
        expect(result[:fail_key_and_errors].length).to eq(1)
        expect(result[:fail_key_and_errors][0][0]).to eq("1")
        expect(result[:fail_key_and_errors][0][1]).to be_a(AreSearch::Error)
        expect(result[:fail_key_and_errors][0][1].message).to match(
            /max_bulk_bytes を超えるデータがあります: id 1 size \d+ \/ 1/,
        )
        expect(result[:check_point_key]).to eq("1")
    end

    it "1件のbyte数がmax_bulk_bytesと一致するsync dataは保持する" do
        action = { index: { _index: "index", _id: "1" } }
        data = { id: 1 }
        max_bulk_bytes = serialized_bytesize(action, data)
        buffer = build_buffer(max_bulk_bytes: max_bulk_bytes)

        buffer.append_sync_data("1", action, data)
        result = buffer.take_all

        expect(result[:keys]).to eq(["1"])
        expect(result[:fail_key_and_errors]).to eq([])
    end

    it "合計byte数がmax_bulk_bytesと一致する場合はcapacity overにならない" do
        first_action = { index: { _index: "index", _id: "1" } }
        first_data = { id: 1 }
        second_action = { index: { _index: "index", _id: "2" } }
        second_data = { id: 2 }
        max_bulk_bytes = serialized_bytesize(first_action, first_data) +
            serialized_bytesize(second_action, second_data)
        buffer = build_buffer(max_bulk_bytes: max_bulk_bytes)

        buffer.append_sync_data("1", first_action, first_data)
        buffer.append_sync_data("2", second_action, second_data)

        expect(buffer.capacity_over?(logger)).to eq(false)
    end

    it "送信待ちと保留中を合わせたbyte数が上限を超えるとcapacity overになる" do
        first_action = { index: { _index: "index", _id: "1" } }
        first_data = { id: 1 }
        second_action = { index: { _index: "index", _id: "2" } }
        second_data = { id: 2 }
        first_size = serialized_bytesize(first_action, first_data)
        second_size = serialized_bytesize(second_action, second_data)
        max_bulk_bytes = first_size + second_size - 1
        buffer = build_buffer(max_bulk_bytes: max_bulk_bytes)

        buffer.append_sync_data("1", first_action, first_data)
        buffer.append_sync_data("2", second_action, second_data)

        expect(buffer.capacity_over?(logger)).to eq(true)
    end

    it "送信待ち件数が上限に達するとcapacity overになる" do
        buffer = build_buffer(max_bulk_count: 1)

        buffer.append_sync_data(
            "1",
            { index: { _index: "index", _id: "1" } },
            { id: 1 },
        )
        expect(buffer.capacity_over?(logger)).to eq(false)

        buffer.append_sync_data(
            "2",
            { index: { _index: "index", _id: "2" } },
            { id: 2 },
        )
        expect(buffer.capacity_over?(logger)).to eq(true)
    end

    it "skipまたはdata failの送信待ち件数が上限に達するとcapacity overになる" do
        skip_buffer = build_buffer(max_skip_count: 1)
        fail_buffer = build_buffer(max_skip_count: 1)

        skip_buffer.append_no_sync_data("1", :skip, nil)
        skip_buffer.append_no_sync_data("2", :skip, nil)

        fail_buffer.append_no_sync_data("1", :fail, RuntimeError.new("first"))
        fail_buffer.append_no_sync_data("2", :fail, RuntimeError.new("second"))

        expect(skip_buffer.capacity_over?(logger)).to eq(true)
        expect(fail_buffer.capacity_over?(logger)).to eq(true)
    end

    it "現在の失敗とbulk全件失敗時の合計がmax_fail_countに達するとcapacity overになる" do
        buffer = build_buffer(
            max_bulk_count: 10,
            max_fail_count: 3,
        )
        fail_logger = double("logger", fail_count: 1)

        buffer.append_sync_data(
            "1",
            { index: { _index: "index", _id: "1" } },
            { id: 1 },
        )
        buffer.append_sync_data(
            "2",
            { index: { _index: "index", _id: "2" } },
            { id: 2 },
        )
        expect(buffer.capacity_over?(fail_logger)).to eq(false)

        buffer.append_sync_data(
            "3",
            { index: { _index: "index", _id: "3" } },
            { id: 3 },
        )
        expect(buffer.capacity_over?(fail_logger)).to eq(true)
    end

    it "失敗件数がmax_fail_countを超えると終了する" do
        buffer = build_buffer(max_fail_count: 2)
        fail_logger = double("logger", fail_count: 3)

        expect(buffer.capacity_over?(fail_logger)).to eq(true)
        expect do
            buffer.check_bulk_exit!(fail_logger)
        end.to raise_error(AreSearch::Error, "失敗が多すぎます: max 2")
    end

    it "空のBufferからtakeしてもnilを返す" do
        buffer = build_buffer

        expect(buffer.take).to eq(nil)
        expect(buffer.take_all).to eq(nil)
    end
end

RSpec.describe AreSearch::BulkIndexer::Logger do
    around do |example|
        Dir.mktmpdir("are_search_bulk_logger") do |dir|
            @logger_dir = dir
            example.run
        end
    end

    let(:check_point_file_path) do
        File.join(@logger_dir, "check_point.log")
    end

    let(:success_file_path) do
        File.join(@logger_dir, "success.log")
    end

    let(:failure_file_path) do
        File.join(@logger_dir, "failure.log")
    end

    let(:data_skip_file_path) do
        File.join(@logger_dir, "data_skip.log")
    end

    let(:data_fail_file_path) do
        File.join(@logger_dir, "data_fail.log")
    end

    let(:log_file_path) do
        File.join(@logger_dir, "bulk.log")
    end

    let(:logger) do
        described_class.new(
            check_point_file_path: check_point_file_path,
            success_file_path:     success_file_path,
            failure_file_path:     failure_file_path,
            data_skip_file_path:   data_skip_file_path,
            data_fail_file_path:   data_fail_file_path,
            log_file_path:         log_file_path,
        )
    end

    # Loggerが読める固定時刻の結果行を返す。
    def logger_result_line(key, result)
        "[2026-08-07T12:00:00.000000+09:00] #{key} #{result}\n"
    end

    describe "#invalid_key?" do
        it "空keyと空白を含むkeyを拒否する" do
            expect(logger.invalid_key?("")).to eq(true)
            expect(logger.invalid_key?("1 2")).to eq(true)
            expect(logger.invalid_key?("1\n2")).to eq(true)
            expect(logger.invalid_key?("123")).to eq(false)
        end
    end

    describe "結果記録" do
        it "successとdata_skipを結果ファイルとbulk.logへ記録する" do
            logger.write_success_result!("1")
            logger.write_data_skip_result!("2")

            expect(File.read(success_file_path)).to match(
                /\A\[[^\]]+\] 1 success\n\z/,
            )
            expect(File.read(data_skip_file_path)).to match(
                /\A\[[^\]]+\] 2 data_skip\n\z/,
            )

            bulk_log = File.read(log_file_path)
            expect(bulk_log).to match(/\[[^\]]+\] 1 success/)
            expect(bulk_log).to match(/\[[^\]]+\] 2 data_skip/)
            expect(logger.fail_count).to eq(0)
        end

        it "bulk失敗とdata生成失敗を別結果ファイルへ記録して失敗件数を増やす" do
            logger.write_failure_result!(
                "1",
                { "type" => "mapper_parsing_exception" },
            )
            logger.write_data_fail_result!(
                "2",
                RuntimeError.new("first line\nsecond line"),
            )

            expect(File.read(failure_file_path)).to match(
                /\A\[[^\]]+\] 1 fail\n\z/,
            )
            expect(File.read(data_fail_file_path)).to match(
                /\A\[[^\]]+\] 2 data_fail\n\z/,
            )

            bulk_log = File.read(log_file_path)
            expect(bulk_log).to include("mapper_parsing_exception")
            expect(bulk_log).to include(
                "RuntimeError: first line second line data_fail",
            )
            expect(logger.fail_count).to eq(2)
        end

        it "checkpointは専用ファイルだけへ記録する" do
            logger.write_check_point!("10")

            expect(File.read(check_point_file_path)).to match(
                /\A\[[^\]]+\] 10 check_point\n\z/,
            )
            expect(File.exist?(log_file_path)).to eq(false)
            expect(logger.fail_count).to eq(0)
        end

        it "checkpoint保存先がnilなら記録しない" do
            nil_checkpoint_logger = described_class.new(
                check_point_file_path: nil,
                success_file_path:     success_file_path,
                failure_file_path:     failure_file_path,
                data_skip_file_path:   data_skip_file_path,
                data_fail_file_path:   data_fail_file_path,
                log_file_path:         log_file_path,
            )

            expect do
                nil_checkpoint_logger.write_check_point!("10")
            end.not_to raise_error

            expect(File.exist?(check_point_file_path)).to eq(false)
            expect(File.exist?(log_file_path)).to eq(false)
        end
    end

    describe "checkpoint読込" do
        it "checkpointファイルの最後のkeyを返す" do
            File.write(
                check_point_file_path,
                logger_result_line("1", "check_point") +
                    logger_result_line("10", "check_point") + "\n",
            )

            expect(logger.get_last_check_point_key).to eq("10")
        end

        it "checkpointファイルが無ければnilを返す" do
            expect(logger.get_last_check_point_key).to eq(nil)
        end

        it "checkpoint形式と一致しない最後の行があれば拒否する" do
            File.write(
                check_point_file_path,
                logger_result_line("10", "success"),
            )

            expect do
                logger.get_last_check_point_key
            end.to raise_error(
                AreSearch::Error,
                /ファイルに不正な行があります/,
            )
        end
    end

    describe "結果読込" do
        it "指定結果ファイルから全keyを順番通り返す" do
            File.write(
                failure_file_path,
                logger_result_line("2", "fail") +
                    logger_result_line("5", "fail"),
            )

            expect(
                logger.read_result_keys(
                    failure_file_path,
                    described_class::FAILURE_RESULT,
                ),
            ).to eq(["2", "5"])
        end

        it "結果形式と一致しない行があれば拒否する" do
            File.write(
                failure_file_path,
                logger_result_line("2", "success"),
            )

            expect do
                logger.read_result_keys(
                    failure_file_path,
                    described_class::FAILURE_RESULT,
                )
            end.to raise_error(
                AreSearch::Error,
                /ファイルに不正な行があります/,
            )
        end

        it "4種類の結果ファイルに記録済みの全keyを返す" do
            File.write(
                success_file_path,
                logger_result_line("1", "success"),
            )
            File.write(
                failure_file_path,
                logger_result_line("2", "fail"),
            )
            File.write(
                data_skip_file_path,
                logger_result_line("3", "data_skip"),
            )
            File.write(
                data_fail_file_path,
                logger_result_line("4", "data_fail"),
            )

            expect(logger.get_all_keys).to eq(["1", "2", "3", "4"])
        end
        it "recoverで解決済みのsuccessとdata_skipのkeyだけを返す" do
            File.write(
                success_file_path,
                logger_result_line("1", "success"),
            )
            File.write(
                failure_file_path,
                logger_result_line("2", "fail"),
            )
            File.write(
                data_skip_file_path,
                logger_result_line("3", "data_skip"),
            )
            File.write(
                data_fail_file_path,
                logger_result_line("4", "data_fail"),
            )

            expect(logger.get_not_fail_keys).to eq(["1", "3"])
        end
    end

    describe "#rename_all" do
        it "Loggerの結果ファイルと追加ファイルを同じ退避ディレクトリへ移動する" do
            additional_file_path = File.join(@logger_dir, "additional.log")
            file_paths = [
                success_file_path,
                failure_file_path,
                data_skip_file_path,
                data_fail_file_path,
                additional_file_path,
            ]

            file_paths.each do |file_path|
                File.write(file_path, File.basename(file_path))
            end

            logger.rename_all([additional_file_path])

            archive_dirs = Dir.children(@logger_dir).select do |name|
                File.directory?(File.join(@logger_dir, name))
            end
            expect(archive_dirs.length).to eq(1)

            archive_dir = File.join(@logger_dir, archive_dirs.first)

            file_paths.each do |file_path|
                expect(File.exist?(file_path)).to eq(false)

                renamed_file_path = File.join(archive_dir, File.basename(file_path))
                expect(File.read(renamed_file_path)).to eq(File.basename(file_path))
            end
        end

        it "存在しない結果ファイルは無視して存在するファイルだけ退避する" do
            File.write(success_file_path, "success")

            logger.rename_all([])

            archive_dirs = Dir.children(@logger_dir).select do |name|
                File.directory?(File.join(@logger_dir, name))
            end
            expect(archive_dirs.length).to eq(1)

            archive_file_path = File.join(@logger_dir, archive_dirs.first, File.basename(success_file_path))
            expect(File.exist?(success_file_path)).to eq(false)
            expect(File.read(archive_file_path)).to eq("success")
        end

        it "途中のrenameに失敗した場合は移動済みファイルを元へ戻す" do
            File.write(success_file_path, "success")
            File.write(failure_file_path, "failure")

            allow(File).to receive(:rename).and_wrap_original do |original_method, file_path, renamed_file_path|
                if file_path == failure_file_path
                    raise Errno::EACCES, file_path
                end

                original_method.call(file_path, renamed_file_path)
            end

            expect do
                logger.rename_all([])
            end.to raise_error(Errno::EACCES)

            expect(File.read(success_file_path)).to eq("success")
            expect(File.read(failure_file_path)).to eq("failure")

            archive_dirs = Dir.children(@logger_dir).select do |name|
                File.directory?(File.join(@logger_dir, name))
            end
            expect(archive_dirs).to eq([])
        end
    end
end
