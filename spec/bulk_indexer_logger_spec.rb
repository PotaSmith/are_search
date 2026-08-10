# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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
