# frozen_string_literal: true

require "spec_helper"
require "rake"
require "active_support/core_ext/numeric/time"
require "tmpdir"
require "fileutils"

RSpec.describe "are_search rake tasks" do
    let(:article_index_target) do
        double(
            "article_index_target",
            target_name:              :default,
            are_search_es_index_name: "test__articles__default",
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            target_name:              :default,
            are_search_es_index_name: "test__documents__default",
        )
    end
    let(:article_model) do
        class_double(
            "Article",
            name:                     "Article",
            are_search_ar_table_name: "articles",
            are_search_index_targets:  [article_index_target],
        )
    end
    let(:document_model) do
        class_double(
            "Document",
            name:                     "Document",
            are_search_ar_table_name: "documents",
            are_search_index_targets:  [document_index_target],
        )
    end
    let(:application) { double("application", eager_load!: true) }

    around do |example|
        Dir.mktmpdir("are_search_rake") do |dir|
            original_lock_dir = AreSearch.lock_dir
            original_index_operation_enabled = AreSearch.index_operation_enabled
            AreSearch.lock_dir = dir
            AreSearch.index_operation_enabled = true

            example.run
        ensure
            AreSearch.lock_dir = original_lock_dir
            AreSearch.index_operation_enabled = original_index_operation_enabled
        end
    end

    before do
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        load File.expand_path("../lib/tasks/are_search.rake", __dir__)

        stub_const("RakeUtils", AreSearch::RakeUtils)

        allow(Rails).to receive(:application).and_return(application)
        allow(ActiveRecord::Base).to receive(:descendants).and_return([article_model, document_model])
        allow(article_model).to receive(:include?).with(AreSearch::Searchable).and_return(true)
        allow(document_model).to receive(:include?).with(AreSearch::Searchable).and_return(true)
        allow(article_model).to receive(:<).and_return(nil)
        allow(document_model).to receive(:<).and_return(nil)
        allow(article_model).to receive(:are_search_index_target).with("default").and_return(article_index_target)
        allow(document_model).to receive(:are_search_index_target).with("default").and_return(document_index_target)

        allow(RakeUtils)
            .to receive(:searchable_index_target_for_reindex)
            .and_return([article_index_target, document_index_target])

        stub_const("Article", article_model)
        stub_const("Document", document_model)
    end

    after do
        Rake.application = Rake::Application.new
    end

    def create_sync_request(attrs = {})
        defaults = {
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "1",
            es_index_name:       "test__articles__default",
            request_sequence:    10,
            request_sequence_at: Time.zone.now,
            retry_count:         0,
            last_error:          nil,
        }

        AreSearch::SyncRequest.create!(defaults.merge(attrs))
    end

    describe "are_search:run_sync_requests" do
        before do
            allow(AreSearch).to receive(:sync_request_delay).and_return(120)
            allow(AreSearch).to receive(:max_retry_count).and_return(3)
            allow(AreSearch).to receive(:sync_request_process_hang_wait).and_return(1800)
            allow(AreSearch).to receive(:max_force_attempt_count).and_return(2)
        end

        it "対象の sync request だけ RecordSync.sync_with_request に渡す" do
            now = Time.zone.now
            old_time = now - 180
            new_time = now - 30

            target = create_sync_request(
                ar_instance_key:  "1",
                request_sequence: 10,
            )
            target.update_columns(created_at: old_time, updated_at: old_time)

            too_new = create_sync_request(
                ar_instance_key:  "2",
                request_sequence: 20,
            )
            too_new.update_columns(created_at: new_time, updated_at: new_time)

            too_many_retry = create_sync_request(
                ar_instance_key:  "3",
                request_sequence: 30,
                retry_count:      3,
                last_error:       "failed",
            )
            too_many_retry.update_columns(created_at: old_time, updated_at: old_time)

            other_model = create_sync_request(
                ar_model_class_name: "Comment",
                index_target_name:   "default",
                ar_instance_key:     "4",
                es_index_name:       "test__comments__default",
                request_sequence:    40,
            )
            other_model.update_columns(created_at: old_time, updated_at: old_time)

            expect(AreSearch::RecordSync)
                .to receive(:sync_with_request) do |actual_index_target, sync_request, processing_token, on_rake:|
                    expect(actual_index_target).to eq(article_index_target)
                    expect(sync_request.id).to eq(target.id)
                    expect(processing_token).to eq(AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN)
                    expect(on_rake).to eq(true)
                end

            expect(AreSearch::RecordSync)
                .not_to receive(:try_force)

            Rake::Task["are_search:run_sync_requests"].invoke
        end

        it "前回の rake task token が残った要求を通常同期で再開する" do
            old_time = Time.zone.now - 3600
            target = create_sync_request(
                ar_instance_key:  "1",
                processing_token: AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN,
                processing_at:    old_time,
            )
            target.update_columns(created_at: old_time, updated_at: old_time)

            expect(AreSearch::RecordSync)
                .to receive(:sync_with_request) do |actual_index_target, sync_request, processing_token, on_rake:|
                    expect(actual_index_target).to eq(article_index_target)
                    expect(sync_request.id).to eq(target.id)
                    expect(processing_token).to eq(AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN)
                    expect(on_rake).to eq(true)
                end

            expect(AreSearch::RecordSync)
                .not_to receive(:try_force)

            Rake::Task["are_search:run_sync_requests"].invoke
        end

        it "現在の es_index_name ではない sync request も RecordSync 側に渡す" do
            old_time = Time.zone.now - 180
            target = create_sync_request(
                ar_instance_key:  "1",
                es_index_name:    "old_articles_default",
                request_sequence: 10,
            )
            target.update_columns(created_at: old_time, updated_at: old_time)

            expect(AreSearch::RecordSync)
                .to receive(:sync_with_request) do |actual_index_target, sync_request, _processing_token, on_rake:|
                    expect(actual_index_target).to eq(article_index_target)
                    expect(sync_request.id).to eq(target.id)
                    expect(sync_request.es_index_name).to eq("old_articles_default")
                    expect(on_rake).to eq(true)
                end

            Rake::Task["are_search:run_sync_requests"].invoke
        end

        it "古い processing_token 付き sync request は RecordSync.try_force に渡す" do
            now = Time.zone.now
            old_time = now - 3600
            new_time = now - 60

            target = create_sync_request(
                ar_instance_key:     "1",
                request_sequence:    10,
                processing_token:    "token-1",
                processing_at:       old_time,
                force_attempt_count: 0,
            )
            target.update_columns(created_at: old_time, updated_at: old_time)

            too_new = create_sync_request(
                ar_instance_key:     "2",
                request_sequence:    20,
                processing_token:    "token-2",
                processing_at:       new_time,
                force_attempt_count: 0,
            )
            too_new.update_columns(created_at: old_time, updated_at: old_time)

            too_many_force = create_sync_request(
                ar_instance_key:     "3",
                request_sequence:    30,
                processing_token:    "token-3",
                processing_at:       old_time,
                force_attempt_count: 2,
            )
            too_many_force.update_columns(created_at: old_time, updated_at: old_time)

            rake_interrupted = create_sync_request(
                ar_instance_key:     "4",
                request_sequence:    40,
                processing_token:    AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN,
                processing_at:       old_time,
                force_attempt_count: 0,
            )
            rake_interrupted.update_columns(created_at: old_time, updated_at: old_time)

            expect(AreSearch::RecordSync)
                .to receive(:sync_with_request)
                .once do |_actual_index_target, sync_request, processing_token, on_rake:|
                    expect(sync_request.id).to eq(rake_interrupted.id)
                    expect(processing_token).to eq(AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN)
                    expect(on_rake).to eq(true)
                end

            expect(AreSearch::RecordSync)
                .to receive(:try_force)
                .once do |actual_index_target, sync_request|
                    expect(actual_index_target).to eq(article_index_target)
                    expect(sync_request.id).to eq(target.id)
                end

            Rake::Task["are_search:run_sync_requests"].invoke
        end

        it "別プロセスが lock を持っている場合は何もしない" do
            lock_path = AreSearch.sync_lock_file_path
            FileUtils.mkdir_p(File.dirname(lock_path))

            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)
                expect(locked).to eq(0)

                expect(AreSearch::RecordSync).not_to receive(:sync_with_request)
                expect(AreSearch::RecordSync).not_to receive(:try_force)

                Rake::Task["are_search:run_sync_requests"].invoke
            end
        end
    end

    describe "are_search:clean_up_all" do
        it "Searchable index ごとに clean up を呼ぶ" do
            allow(AreSearch::IndexManager)
                .to receive(:es_clean_up)
                .with("test__articles__default")
                .and_return(true)

            allow(AreSearch::IndexManager)
                .to receive(:es_clean_up)
                .with("test__documents__default")
                .and_return(false)

            expect do
                Rake::Task["are_search:clean_up_all"].invoke
            end.to output(
                "[AreSearch] clean_up done: test__articles__default\n" \
                "[AreSearch] clean_up skipped: test__documents__default locked\n",
            ).to_stdout
        end

        it "1 index の clean up が失敗しても残り index を処理する" do
            allow(AreSearch::IndexManager)
                .to receive(:es_clean_up)
                .with("test__articles__default")
                .and_raise(RuntimeError, "delete failed")

            allow(AreSearch::IndexManager)
                .to receive(:es_clean_up)
                .with("test__documents__default")
                .and_return(true)

            expect do
                Rake::Task["are_search:clean_up_all"].invoke
            end.to output(
                "[AreSearch] clean_up failed: test__articles__default RuntimeError: delete failed\n" \
                "[AreSearch] clean_up done: test__documents__default\n",
            ).to_stdout
        end

        it "index 操作が許可されていない場合は例外を再送出する" do
            allow(AreSearch::IndexManager)
                .to receive(:es_clean_up)
                .with("test__articles__default")
                .and_raise(AreSearch::IndexOperationViolation, "not allowed")

            expect(AreSearch::IndexManager)
                .not_to receive(:es_clean_up)
                .with("test__documents__default")

            expect do
                Rake::Task["are_search:clean_up_all"].invoke
            end.to raise_error(AreSearch::IndexOperationViolation, "not allowed")
        end
    end

    describe "are_search:check_index_status" do
        it "marker と lock と Elasticsearch 状態を出力する" do
            AreSearch::IndexMarker.create!(
                es_index_name: "test__documents__default",
                operation:     "reindex",
                owner_token:   SecureRandom.uuid,
                owner_host:    "test-host",
                owner_pid:     12345,
                started_at:    Time.zone.now,
            )

            allow(AreSearch::IndexManager)
                .to receive(:es_index_status)
                .with("test__articles__default")
                .and_return(
                    {
                        alias_name:             "test__articles__default",
                        alias_exists:           true,
                        current_physical_names: ["test__articles__default__2026_07_04_00_00_00_000000"],
                        physical_indexes:       [
                            {
                                name:    "test__articles__default__2026_07_04_00_00_00_000000",
                                current: true,
                            },
                        ],
                        warnings:               [],
                    },
                )

            allow(AreSearch::IndexManager)
                .to receive(:es_index_status)
                .with("test__documents__default")
                .and_return(
                    {
                        alias_name:             "test__documents__default",
                        alias_exists:           false,
                        current_physical_names: [],
                        physical_indexes:       [],
                        warnings:               ["alias missing"],
                    },
                )

            expect do
                Rake::Task["are_search:check_index_status"].invoke
            end.to output(
                /index status: test__articles__default.*alias:\s+exists.*current physical:.*test__articles__default__2026_07_04_00_00_00_000000.*physical indexes:.*test__articles__default__2026_07_04_00_00_00_000000 current.*warning:\s+none.*index status: test__documents__default.*marker:\s+exists.*alias:\s+missing.*warning:\s+alias missing.*warning:\s+marker exists/m,
            ).to_stdout
        end

        it "Elasticsearch 状態の取得に失敗しても marker と lock は出力する" do
            allow(AreSearch::IndexManager)
                .to receive(:es_index_status)
                .with("test__articles__default")
                .and_raise(RuntimeError, "es down")

            allow(AreSearch::IndexManager)
                .to receive(:es_index_status)
                .with("test__documents__default")
                .and_return(
                    {
                        alias_name:             "test__documents__default",
                        alias_exists:           true,
                        current_physical_names: ["test__documents__default__2026_07_04_00_00_00_000000"],
                        physical_indexes:       [],
                        warnings:               [],
                    },
                )

            expect do
                Rake::Task["are_search:check_index_status"].invoke
            end.to output(
                /index status: test__articles__default.*marker:\s+none.*elasticsearch: failed RuntimeError: es down.*index status: test__documents__default/m,
            ).to_stdout
        end
    end

    describe "are_search:check_sync_request_status" do
        it "marker・モデル別件数・テーブル別エラー上位20件を固定幅で出力する" do
            article_archive_model = class_double(
                "ArticleArchive",
                name:       "ArticleArchive",
                are_search_ar_table_name: "articles",
            )
            stub_const("ArticleArchive", article_archive_model)

            AreSearch::IndexMarker.create!(
                es_index_name: "test__articles__default",
                operation:     "manual",
                owner_token:   SecureRandom.uuid,
                owner_host:    "test-host",
                owner_pid:     12345,
                started_at:    Time.zone.parse("2026-07-11 10:20:30"),
                message:       "maintenance",
            )

            create_sync_request(
                ar_instance_key: "1",
                last_error:     "index marked",
            )
            create_sync_request(
                ar_instance_key: "2",
                last_error:     "index marked",
            )
            create_sync_request(
                ar_instance_key: "3",
            )
            create_sync_request(
                ar_model_class_name: "ArticleArchive",
                ar_instance_key:     "4",
                last_error:          "index marked",
            )
            create_sync_request(
                ar_model_class_name: "Document",
                ar_instance_key:     "5",
                es_index_name:       "test__documents__default",
                last_error:          "timeout",
            )

            expected_output = <<~OUTPUT
                -------------------------------------------------------------------------
                [AreSearch] sync request status
                -------------------------------------------------------------------------
                マーカー状況

                ESインデックス名         操作    開始日時             ホスト     PID    メッセージ
                test__articles__default  manual  2026-07-11 10:20:30  test-host  12345  maintenance

                -------------------------------------------------------------------------
                リクエスト数

                テーブル名  モデル          データ数  エラー数
                articles    Article         3         2
                articles    ArticleArchive  1         1
                documents   Document        1         1

                -------------------------------------------------------------------------
                エラー内容 トップ20

                テーブル名  内容          件数
                articles    index marked  3
                documents   timeout       1

            OUTPUT

            expect do
                Rake::Task["are_search:check_sync_request_status"].invoke
            end.to output(expected_output).to_stdout
        end

        it "marker・sync request・エラーが無い場合は各区分に、なしと出力する" do
            expected_output = <<~OUTPUT
                -------------------------------------------------------------------------
                [AreSearch] sync request status
                -------------------------------------------------------------------------
                マーカー状況

                なし

                -------------------------------------------------------------------------
                リクエスト数

                なし

                -------------------------------------------------------------------------
                エラー内容 トップ20

                なし

            OUTPUT

            expect do
                Rake::Task["are_search:check_sync_request_status"].invoke
            end.to output(expected_output).to_stdout
        end

        it "エラー内容は件数順の上位20件だけを返す" do
            21.times do |index|
                create_sync_request(
                    ar_instance_key: index.to_s,
                    last_error:     "error #{index.to_s.rjust(2, '0')}",
                )
            end

            rows = AreSearch::RakeUtils.sync_request_error_status_rows(20)

            expect(rows.length).to eq(20)
            expect(rows[0]).to eq(["articles", "error 00", "1"])
            expect(rows[19]).to eq(["articles", "error 19", "1"])
            expect(rows).not_to include(["articles", "error 20", "1"])
        end
    end


    describe "are_search:mark_all" do
        it "manual marker を作成し、既存 marker がある index はスキップする" do
            existing_marker = AreSearch::IndexMarker.create!(
                es_index_name: "test__documents__default",
                operation:     "reindex",
                owner_token:   SecureRandom.uuid,
                owner_host:    "test-host",
                owner_pid:     12345,
                started_at:    Time.zone.now,
            )

            expect do
                Rake::Task["are_search:mark_all"].invoke
            end.to output(
                /mark_all marked: test__articles__default marker_id=\d+.*mark_all skipped: test__documents__default existing_operation=reindex marker_id=#{existing_marker.id}/m,
            ).to_stdout

            article_marker = AreSearch::IndexMarker.find_by(es_index_name: "test__articles__default")
            document_marker = AreSearch::IndexMarker.find_by(es_index_name: "test__documents__default")

            expect(article_marker.operation).to eq("manual")
            expect(document_marker.id).to eq(existing_marker.id)
            expect(document_marker.operation).to eq("reindex")
        end
    end

    describe "are_search:unmark_all" do
        it "manual marker だけを削除する" do
            manual_marker = AreSearch::IndexMarker.create!(
                es_index_name: "test__articles__default",
                operation:     "manual",
                owner_token:   SecureRandom.uuid,
                owner_host:    "test-host",
                owner_pid:     12345,
                started_at:    Time.zone.now,
            )
            reindex_marker = AreSearch::IndexMarker.create!(
                es_index_name: "test__documents__default",
                operation:     "reindex",
                owner_token:   SecureRandom.uuid,
                owner_host:    "test-host",
                owner_pid:     12345,
                started_at:    Time.zone.now,
            )

            expect do
                Rake::Task["are_search:unmark_all"].invoke
            end.to output(
                /unmark_all deleted: test__articles__default count=1.*unmark_all skipped: test__documents__default manual marker not found/m,
            ).to_stdout

            expect(AreSearch::IndexMarker.find_by(id: manual_marker.id)).to eq(nil)
            expect(AreSearch::IndexMarker.find_by(id: reindex_marker.id)).not_to eq(nil)
        end
    end

    describe "are_search:reindex_all_for_es_version_up" do
        let(:indices) { double("indices") }
        let(:client) { double("client", indices: indices) }

        before do
            allow(AreSearch).to receive(:client).and_return(client)
            allow(AreSearch).to receive(:index_prefix).and_return("test")
        end

        it "sync request が残っている場合はエラーにする" do
            create_sync_request

            expect(indices).not_to receive(:get)
            expect(article_index_target).not_to receive(:are_search_es_reindex)
            expect(document_index_target).not_to receive(:are_search_es_reindex)

            expect do
                Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
            end.to raise_error(
                AreSearch::Error,
                "[AreSearch] are_search_sync_requests に 1 件残っているため reindex できません",
            )
        end

        it "現在の alias に接続されていない index があればエラーにする" do
            allow(indices)
                .to receive(:get)
                .with(index: "test__*")
                .and_return(
                    {
                        "test__articles__default__2026_07_10_00_00_00_000000" => {},
                        "test__documents__default__2026_07_10_00_00_00_000000" => {},
                        "test__articles__default__2026_07_09_00_00_00_000000" => {},
                    },
                )

            allow(AreSearch::IndexManager)
                .to receive(:es_get_alias_physical_names)
                .with("test__articles__default")
                .and_return(["test__articles__default__2026_07_10_00_00_00_000000"])

            allow(AreSearch::IndexManager)
                .to receive(:es_get_alias_physical_names)
                .with("test__documents__default")
                .and_return(["test__documents__default__2026_07_10_00_00_00_000000"])

            expect($stdin).not_to receive(:gets)
            expect(article_index_target).not_to receive(:are_search_es_reindex)
            expect(document_index_target).not_to receive(:are_search_es_reindex)

            expect do
                Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
            end.to raise_error(
                AreSearch::Error,
                /test__articles__default__2026_07_09_00_00_00_000000/,
            )
        end

        it "確認で y 以外が入力された場合は reindex しない" do
            allow(indices)
                .to receive(:get)
                .with(index: "test__*")
                .and_return(
                    {
                        "test__articles__default__2026_07_10_00_00_00_000000" => {},
                        "test__documents__default__2026_07_10_00_00_00_000000" => {},
                    },
                )

            allow(AreSearch::IndexManager)
                .to receive(:es_get_alias_physical_names)
                .with("test__articles__default")
                .and_return(["test__articles__default__2026_07_10_00_00_00_000000"])

            allow(AreSearch::IndexManager)
                .to receive(:es_get_alias_physical_names)
                .with("test__documents__default")
                .and_return(["test__documents__default__2026_07_10_00_00_00_000000"])

            allow($stdin).to receive(:gets).and_return("n\n")

            expect(article_index_target).not_to receive(:are_search_es_reindex)
            expect(document_index_target).not_to receive(:are_search_es_reindex)

            expect do
                Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
            end.to output(
                "以下の index を reindex します。\n" \
                "\n" \
                "  test__articles__default\n" \
                "  test__documents__default\n" \
                "\n" \
                "実行しますか？ [y/N]: [AreSearch] reindex canceled.\n",
            ).to_stdout
        end

        it "確認で y が入力された場合は全 index target を reindex する" do
            allow(indices)
                .to receive(:get)
                .with(index: "test__*")
                .and_return(
                    {
                        "test__articles__default__2026_07_10_00_00_00_000000" => {},
                        "test__documents__default__2026_07_10_00_00_00_000000" => {},
                    },
                )

            allow(AreSearch::IndexManager)
                .to receive(:es_get_alias_physical_names)
                .with("test__articles__default")
                .and_return(["test__articles__default__2026_07_10_00_00_00_000000"])

            allow(AreSearch::IndexManager)
                .to receive(:es_get_alias_physical_names)
                .with("test__documents__default")
                .and_return(["test__documents__default__2026_07_10_00_00_00_000000"])

            allow($stdin).to receive(:gets).and_return("y\n")

            expect(article_index_target)
                .to receive(:are_search_es_reindex)
                .ordered
                .and_return([])

            expect(document_index_target)
                .to receive(:are_search_es_reindex)
                .ordered
                .and_return([])

            expect do
                Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
            end.to output(
                /reindex done: test__articles__default.*reindex done: test__documents__default/m,
            ).to_stdout
        end
    end
end
