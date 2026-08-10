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

RSpec.describe AreSearch::SyncJob do
    let(:database_name)         { "app_test" }
    let(:ar_model_class_name)   { "Article" }
    let(:ar_instance_key)       { "123" }
    let(:index_alias_name)         { "test__articles__default" }
    let(:sync_stage_name)            { "default" }
    let(:processing_token)      { "token-1" }
    let(:current_database_name) { database_name }
    let(:db_config)             { double("db_config", database: current_database_name) }
    let(:article_model)         { Class.new }

    before do
        stub_const(ar_model_class_name, article_model)

        allow(article_model)
            .to receive(:connection_db_config)
            .and_return(db_config)
    end

    describe "#perform" do
        context "model class が存在しない場合" do
            it "constantize の例外を握りつぶさない" do
                expect do
                    described_class.new.perform(
                        database_name,
                        "MissingArticle",
                        ar_instance_key,
                        index_alias_name,
                        sync_stage_name,
                        processing_token,
                    )
                end.to raise_error(NameError)
            end
        end

        context "Job 作成時の database_name と worker の database_name が一致する場合" do
            let(:current_database_name) { "app_test" }

            it "SyncRequest.are_search_find_and_try_sync に processing_token と reraise: true で委譲する" do
                expect(AreSearch::SyncRequest)
                    .to receive(:are_search_find_and_try_sync)
                    .with(
                        ar_model_class_name,
                        ar_instance_key,
                        index_alias_name,
                        sync_stage_name,
                        processing_token,
                        reraise: true,
                    )

                described_class.new.perform(
                    database_name,
                    ar_model_class_name,
                    ar_instance_key,
                    index_alias_name,
                    sync_stage_name,
                    processing_token,
                )
            end
        end

        context "Job 作成時の database_name と worker の database_name が一致しない場合" do
            let(:current_database_name) { "other_test" }

            it "SyncRequest.are_search_find_and_try_sync を呼ばずに終了する" do
                expect(AreSearch::SyncRequest)
                    .not_to receive(:are_search_find_and_try_sync)

                result = described_class.new.perform(
                    database_name,
                    ar_model_class_name,
                    ar_instance_key,
                    index_alias_name,
                    sync_stage_name,
                    processing_token,
                )

                expect(result).to be_nil
            end
        end
    end
end

RSpec.describe AreSearch::Searchable do
    let(:logger) { double("logger") }

    before do
        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    def build_searchable_class
        Class.new do
            def self.validations
                @validations ||= []
            end

            def self.save_callbacks
                @save_callbacks ||= []
            end

            def self.touch_callbacks
                @touch_callbacks ||= []
            end

            def self.destroy_callbacks
                @destroy_callbacks ||= []
            end

            def self.commit_callbacks
                @commit_callbacks ||= []
            end

            def self.validate(callback_name)
                validations << callback_name
            end

            def self.after_save(callback_name)
                save_callbacks << callback_name
            end

            def self.after_touch(callback_name)
                touch_callbacks << callback_name
            end

            def self.after_destroy(callback_name)
                destroy_callbacks << callback_name
            end

            def self.after_commit(callback_name)
                commit_callbacks << callback_name
            end

            def self.table_name
                "articles"
            end

            def self.connection_db_config
                Struct.new(:database).new("app_test")
            end

            def self.model_name
                Struct.new(:human).new("Article")
            end

            def self.are_search_index_mappings
                {
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title: { type: "text" },
                        },
                    },
                }
            end

            def self.are_search_all_sync_stage_names
                {
                    default: ["default"],
                }
            end

            def are_search_index_data(_index_target_name, _sync_stage_name)
                { title: "hello" }
            end

            attr_accessor :id
        end
    end

    describe "#are_search_index_data_validate" do

        it "data に予約フィールドがあれば validation error を追加する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            errors = double("errors")

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "default")
                .and_return(
                    title: "hello",
                    are_search_reserved_ar_instance_key: "123",
                )

            allow(record)
                .to receive(:errors)
                .and_return(errors)

            allow(AreSearch::IndexDataValidator)
                .to receive(:validate)
                .and_return([])

            expect(logger)
                .to receive(:debug) do |&block|
                    expect(block.call).to include("予約フィールド")
                end

            expect(errors)
                .to receive(:add)
                .with(:base, "[Article] 検索データが不正です")

            record.are_search_index_data_validate
        end

        it "target ごとの mappings と data を IndexDataValidator に渡す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            mappings = { properties: { title: { type: "text" } } }
            data = { title: "hello" }
            errors = double("errors")

            allow(record = model_class.new)
                .to receive(:are_search_index_data)
                .with(:default, "default")
                .and_return(data)

            allow(record)
                .to receive(:errors)
                .and_return(errors)

            expect(AreSearch::IndexDataValidator)
                .to receive(:validate)
                .with(mappings, data)
                .and_return([])

            expect(errors)
                .not_to receive(:add)

            record.are_search_index_data_validate
        end

        it "indexable ではない target は検証しない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(record)
                .to receive(:are_search_indexable?)
                .with(:default, "default")
                .and_return(false)

            expect(record)
                .not_to receive(:are_search_index_data)

            record.are_search_index_data_validate
        end

        it "不整合があれば validation error を追加する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            data = { title: 123 }
            errors = double("errors")
            violations = ["title は text 型ですが String ではありません: Integer"]
            record = model_class.new
            record.id = 123

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "default")
                .and_return(data)

            allow(record)
                .to receive(:errors)
                .and_return(errors)

            allow(AreSearch::IndexDataValidator)
                .to receive(:validate)
                .and_return(violations)

            expect(errors)
                .to receive(:add)
                .with(:base, "[Article] 検索データが不正です")

            record.are_search_index_data_validate
        end

        it "are_search_index_data の例外は握りつぶさない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "default")
                .and_raise(RuntimeError, "data failed")

            expect(AreSearch::IndexDataValidator)
                .not_to receive(:validate)

            expect do
                record.are_search_index_data_validate
            end.to raise_error(RuntimeError, "data failed")
        end
    end

    describe "#are_search_enqueue_sync_request" do
        it "同じ世代番号と時刻でtargetごとにDB固有処理へ同期要求を渡す" do
            model_class = build_searchable_class
            stub_const("Article", model_class)
            model_class.include(described_class)
            request_sequence_at = Time.zone.now
            database_specific = class_double(AreSearch::DatabaseSpecific)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    {
                        default: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                title: { type: "text" },
                            },
                        },
                        archive: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                title: { type: "text" },
                            },
                        },
                    },
                )

            allow(model_class)
                .to receive(:are_search_all_sync_stage_names)
                .and_return(
                    default: ["default"],
                    archive: ["default"],
                )

            allow(model_class)
                .to receive(:are_search_sync_stage_names_on_enqueue)
                .and_return(
                    default: ["default"],
                    archive: ["default"],
                )

            allow(model_class)
                .to receive(:are_search_sync_stage_names_on_after_commit)
                .and_return({})

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(AreSearch)
                .to receive(:database_specific)
                .and_return(database_specific)

            expect(database_specific)
                .to receive(:next_request_sequence)
                .once
                .and_return(42)

            expect(Time.zone)
                .to receive(:now)
                .once
                .and_return(request_sequence_at)

            record = model_class.new
            record.id = 123

            expect(database_specific)
                .to receive(:upsert)
                .with(
                    ar_model_class_name: "Article",
                    index_target_name:   :default,
                    ar_instance_key:     "123",
                    index_alias_name:       "test__articles__default",
                    sync_stage_name:          "default",
                    request_sequence:    42,
                    request_sequence_at: request_sequence_at,
                )
                .ordered

            expect(database_specific)
                .to receive(:upsert)
                .with(
                    ar_model_class_name: "Article",
                    index_target_name:   :archive,
                    ar_instance_key:     "123",
                    index_alias_name:       "test__articles__archive",
                    sync_stage_name:          "default",
                    request_sequence:    42,
                    request_sequence_at: request_sequence_at,
                )
                .ordered

            record.are_search_enqueue_sync_request
        end
    end

    describe "#are_search_upsert_sync_request" do
        it "allに存在しないstageを拒否する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)

            expect(AreSearch.database_specific)
                .not_to receive(:upsert)

            expect do
                record.are_search_upsert_sync_request_with_sequence(
                    index_target,
                    "unknown",
                    42,
                    Time.zone.now,
                )
            end.to raise_error(
                ArgumentError,
                /are_search_all_sync_stage_names\[:default\] に存在しない stage/,
            )
        end
    end

    describe "#are_search_enqueue_sync_job" do
        it "commit 後に同期キーと processing_token を含めて SyncJob を enqueue する" do
            model_class = build_searchable_class
            stub_const("Article", model_class)
            model_class.include(described_class)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(SecureRandom)
                .to receive(:uuid)
                .and_return("token-1")

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)

            expect(AreSearch::SyncJob)
                .to receive(:perform_later)
                .with(
                    "app_test",
                    "Article",
                    "123",
                    "test__articles__default",
                    "default",
                    "token-1",
                )

            record.are_search_enqueue_sync_job(index_target, "default")
        end
    end

    describe "#are_search_after_commit" do
        it "after_commit_mode が :job なら SyncJob を enqueue する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:job)

            expect(record)
                .to receive(:are_search_enqueue_sync_job)
                .with(kind_of(AreSearch::IndexTarget), "default")

            record.are_search_after_commit
        end

        it "after_commit_mode が :direct なら直接同期する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:direct)

            index_target = model_class.are_search_index_target(:default)
            record.id = 123

            expect(record)
                .not_to receive(:are_search_enqueue_sync_job)

            expect(index_target)
                .to receive(:are_search_sync)
                .with(123, "default")

            record.are_search_after_commit
        end

        it "after_commit_mode が :job でenqueueがfalseならエラーをログへ残す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            record.id = 123

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:job)

            expect(record)
                .to receive(:are_search_enqueue_sync_job)
                .with(kind_of(AreSearch::IndexTarget), "default")
                .and_return(false)

            expect(logger).to receive(:error) do |&block|
                message = block.call
                expect(message).to include("after_commit sync failed")
                expect(message).to include("sync_stage=default")
                expect(message).to include("mode=job")
            end

            record.are_search_after_commit
        end

        it "after_commit_mode が :direct で同期がfalseならエラーをログへ残す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            record.id = 123

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:direct)

            index_target = model_class.are_search_index_target(:default)

            expect(index_target)
                .to receive(:are_search_sync)
                .with(123, "default")
                .and_return(false)

            expect(logger).to receive(:error) do |&block|
                message = block.call
                expect(message).to include("after_commit sync failed")
                expect(message).to include("sync_stage=default")
                expect(message).to include("mode=direct")
            end

            record.are_search_after_commit
        end

        it "1stageのJob登録で例外が出ても残りのstageを継続する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            record.id = 123

            allow(model_class)
                .to receive(:are_search_all_sync_stage_names)
                .and_return(default: ["first", "second"])

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:job)

            sync_stage_names = []
            allow(record).to receive(:are_search_enqueue_sync_job) do |_index_target, sync_stage_name|
                sync_stage_names << sync_stage_name
                raise RuntimeError, "enqueue failed" if sync_stage_name == "first"

                true
            end

            expect(logger).to receive(:error) do |&block|
                message = block.call
                expect(message).to include("sync_stage=first")
                expect(message).to include("RuntimeError: enqueue failed")
            end

            record.are_search_after_commit

            expect(sync_stage_names).to eq(["first", "second"])
        end

        it "after_commit_mode が :none なら何もしない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:none)

            index_target = model_class.are_search_index_target(:default)

            expect(record)
                .not_to receive(:are_search_enqueue_sync_job)

            expect(index_target)
                .not_to receive(:are_search_sync)

            record.are_search_after_commit
        end
    end

end
