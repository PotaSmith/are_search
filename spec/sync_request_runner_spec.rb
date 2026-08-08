# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::SyncRequestRunner do
    let(:article_model) do
        class_double(
            "Article",
            name: "Article",
        )
    end

    around do |example|
        Dir.mktmpdir("are_search_sync_request_runner") do |dir|
            @lock_file_path = File.join(dir, "sync.lock")
            example.run
        end
    end

    # Runnerの対象選択に使う同期要求を作成する。
    def create_sync_request(attrs = {})
        defaults = {
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "1",
            index_alias_name:       "test__articles__default",
            sync_stage_name:          "default",
            request_sequence:    10,
            request_sequence_at: Time.zone.now,
            sync_try_count:   0,
            callback_try_count:  0,
            last_error:          nil,
        }

        AreSearch::SyncRequest.create!(defaults.merge(attrs))
    end

    it "指定したmodelとscopeの通常同期とforce同期だけを処理する" do
        normal_request = create_sync_request(
            ar_instance_key: "1",
        )
        interrupted_request = create_sync_request(
            ar_instance_key:  "2",
            processing_token: "runner-token",
            processing_at:    Time.zone.now,
        )
        force_request = create_sync_request(
            ar_instance_key:  "3",
            processing_token: "job-token",
            processing_at:    Time.zone.now,
        )
        create_sync_request(
            ar_instance_key: "4",
            sync_stage_name:      "with_external_file",
        )
        create_sync_request(
            ar_model_class_name: "Comment",
            ar_instance_key:     "5",
            index_alias_name:       "test__comments__default",
        )

        normal_scope = AreSearch::SyncRequest.where(
            sync_stage_name: "default",
        )
        force_scope = AreSearch::SyncRequest.where(
            sync_stage_name: "default",
        )

        normal_calls = []
        force_calls = []

        allow_any_instance_of(AreSearch::SyncRequest)
            .to receive(:are_search_try_sync) do |sync_request, token, on_rake:|
                normal_calls << [sync_request.id, token, on_rake]
            end

        allow_any_instance_of(AreSearch::SyncRequest)
            .to receive(:are_search_try_force_sync) do |sync_request|
                force_calls << sync_request.id
            end

        result = described_class.run(
            models:           [article_model],
            normal_scope:     normal_scope,
            force_scope:      force_scope,
            processing_token: "runner-token",
            lock_file_path:   @lock_file_path,
        )

        expect(result).to eq(
            normal_count: 2,
            force_count:  1,
        )
        expect(normal_calls).to eq([
            [normal_request.id, "runner-token", true],
            [interrupted_request.id, "runner-token", true],
        ])
        expect(force_calls).to eq([force_request.id])
    end

    it "利用側から渡されたscopeの条件を維持する" do
        normal_request = create_sync_request(
            ar_instance_key: "1",
        )
        force_request = create_sync_request(
            ar_instance_key:  "2",
            processing_token: "job-token",
            processing_at:    Time.zone.now,
        )
        create_sync_request(
            ar_instance_key: "3",
        )

        normal_scope = AreSearch::SyncRequest.where(id: normal_request.id)
        force_scope = AreSearch::SyncRequest.where(id: force_request.id)

        normal_calls = []
        force_calls = []

        allow_any_instance_of(AreSearch::SyncRequest)
            .to receive(:are_search_try_sync) do |sync_request, token, on_rake:|
                normal_calls << [sync_request.id, token, on_rake]
            end

        allow_any_instance_of(AreSearch::SyncRequest)
            .to receive(:are_search_try_force_sync) do |sync_request|
                force_calls << sync_request.id
            end

        result = described_class.run(
            models:           [article_model],
            normal_scope:     normal_scope,
            force_scope:      force_scope,
            processing_token: "runner-token",
            lock_file_path:   @lock_file_path,
        )

        expect(result).to eq(
            normal_count: 1,
            force_count:  1,
        )
        expect(normal_calls).to eq([
            [normal_request.id, "runner-token", true],
        ])
        expect(force_calls).to eq([force_request.id])
    end

    it "lockを取得できない場合は処理せずnilを返す" do
        FileUtils.mkdir_p(File.dirname(@lock_file_path))

        File.open(@lock_file_path, File::RDWR | File::CREAT) do |lock_file|
            locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)
            expect(locked).to eq(0)

            expect_any_instance_of(AreSearch::SyncRequest).not_to receive(:are_search_try_sync)
            expect_any_instance_of(AreSearch::SyncRequest).not_to receive(:are_search_try_force_sync)

            result = described_class.run(
                models:           [article_model],
                normal_scope:     AreSearch::SyncRequest.all,
                force_scope:      AreSearch::SyncRequest.all,
                processing_token: "runner-token",
                lock_file_path:   @lock_file_path,
            )

            expect(result).to eq(nil)
        end
    end

    it "processing_tokenが空なら拒否する" do
        expect do
            described_class.run(
                models:           [article_model],
                normal_scope:     AreSearch::SyncRequest.all,
                force_scope:      AreSearch::SyncRequest.all,
                processing_token: nil,
                lock_file_path:   @lock_file_path,
            )
        end.to raise_error(ArgumentError, "processing_token を指定してください")
    end

    it "lock_file_pathが空なら拒否する" do
        expect do
            described_class.run(
                models:           [article_model],
                normal_scope:     AreSearch::SyncRequest.all,
                force_scope:      AreSearch::SyncRequest.all,
                processing_token: "runner-token",
                lock_file_path:   nil,
            )
        end.to raise_error(ArgumentError, "lock_file_path を指定してください")
    end
end
