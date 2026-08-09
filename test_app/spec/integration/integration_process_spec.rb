# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch process integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    it "fork後は親から継承したElasticsearch clientを再生成して接続できる" do
        parent_client = AreSearch.client
        parent_client.info

        reader, writer = IO.pipe

        child_pid = fork do
            reader.close

            begin
                inherited_client = Thread.current.thread_variable_get(
                    :are_search_client,
                )
                child_client = AreSearch.client
                info = child_client.info

                Marshal.dump(
                    {
                        reused_inherited_client: child_client.equal?(inherited_client),
                        cached_pid: Thread.current.thread_variable_get(
                            :are_search_client_pid,
                        ),
                        process_pid: Process.pid,
                        version: info.dig("version", "number"),
                    },
                    writer,
                )
            rescue StandardError => error
                Marshal.dump(
                    {
                        error_class:   error.class.name,
                        error_message: error.message,
                    },
                    writer,
                )
            ensure
                writer.close
            end

            exit! 0
        end

        writer.close
        payload = Marshal.load(reader)
        reader.close
        Process.wait(child_pid)

        expect(payload[:error_class]).to eq(nil)
        expect(payload[:reused_inherited_client]).to eq(false)
        expect(payload[:cached_pid]).to eq(payload[:process_pid])
        expect(payload[:version]).not_to eq(nil)
    end

    it "別プロセスがsync flockを保持中はRunnerをskipして解放後は実行できる" do
        Dir.mktmpdir("are_search_process_integration") do |dir|
            lock_file_path = File.join(dir, "sync.lock")
            ready_reader, ready_writer = IO.pipe
            release_reader, release_writer = IO.pipe

            child_pid = fork do
                ready_reader.close
                release_writer.close

                File.open(lock_file_path, File::RDWR | File::CREAT) do |lock_file|
                    lock_file.flock(File::LOCK_EX)
                    ready_writer.write("1")
                    ready_writer.flush
                    ready_writer.close

                    release_reader.read(1)
                end

                release_reader.close
                exit! 0
            end

            ready_writer.close
            release_reader.close
            ready_reader.read(1)
            ready_reader.close

            locked_result = AreSearch::SyncRequestRunner.run(
                models:           [],
                normal_scope:     nil,
                force_scope:      nil,
                processing_token: "integration",
                lock_file_path:   lock_file_path,
            )

            expect(locked_result).to eq(nil)

            release_writer.write("1")
            release_writer.close
            Process.wait(child_pid)

            unlocked_result = AreSearch::SyncRequestRunner.run(
                models:           [DocumentFirst],
                normal_scope:     AreSearch::SyncRequest.none,
                force_scope:      AreSearch::SyncRequest.none,
                processing_token: "integration",
                lock_file_path:   lock_file_path,
            )

            expect(unlocked_result).to eq(
                normal_count: 0,
                force_count:  0,
            )
        end
    end
end
