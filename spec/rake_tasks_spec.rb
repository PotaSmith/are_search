# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "../lib/are_search/rake_utils"
require "rake"
require "active_support/core_ext/numeric/time"
require "tmpdir"
require "fileutils"
require "action_mailer"
require "rails/generators"
require "generators/are_search/sample_generator"

RSpec.describe "are_search rake tasks" do
    let(:article_index_target) do
        double(
            "article_index_target",
            index_target_name:              :default,
            are_search_index_alias_name: "test__articles__default",
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            index_target_name:              :default,
            are_search_index_alias_name: "test__documents__default",
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
            original_rake_operation_enabled = AreSearch.rake_operation_enabled
            AreSearch.lock_dir = dir
            AreSearch.index_operation_enabled = true
            AreSearch.rake_operation_enabled = true

            example.run
        ensure
            AreSearch.lock_dir = original_lock_dir
            AreSearch.index_operation_enabled = original_index_operation_enabled
            AreSearch.rake_operation_enabled = original_rake_operation_enabled
        end
    end

    before do
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        load File.expand_path("../lib/tasks/are_search.rake", __dir__)

        allow(Rails).to receive(:application).and_return(application)
        allow(ActiveRecord::Base).to receive(:descendants).and_return([article_model, document_model])
        allow(article_model).to receive(:include?).with(AreSearch::Searchable).and_return(true)
        allow(document_model).to receive(:include?).with(AreSearch::Searchable).and_return(true)
        allow(article_model).to receive(:<).and_return(nil)
        allow(document_model).to receive(:<).and_return(nil)
        allow(article_model).to receive(:are_search_index_target).with("default").and_return(article_index_target)
        allow(document_model).to receive(:are_search_index_target).with("default").and_return(document_index_target)

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

    describe "are_search:check_all_models" do
        it "モデル設定エラーがある場合はindex名の所有関係を検査しない" do
            allow(ActiveRecord::Base)
                .to receive(:descendants)
                .and_return([article_model])

            enqueue_callback = double(
                "enqueue_callback",
                kind:   :after,
                filter: :are_search_enqueue_sync_request,
            )
            commit_callback = double(
                "commit_callback",
                kind:   :after,
                filter: :are_search_after_commit,
            )

            allow(article_model).to receive(:_save_callbacks).and_return([enqueue_callback])
            allow(article_model).to receive(:_destroy_callbacks).and_return([enqueue_callback])
            allow(article_model).to receive(:_touch_callbacks).and_return([enqueue_callback])
            allow(article_model).to receive(:_commit_callbacks).and_return([commit_callback])

            allow(AreSearch::RakeUtils::CheckAllModels)
                .to receive(:check_callback_order)

            expect(AreSearch::RakeUtils::CheckAllModels)
                .to receive(:model_check) do |_model, errors|
                    errors << "Article: invalid setting"
                end

            expect(AreSearch::RakeUtils::CheckAllModels)
                .not_to receive(:validate_searchable_index_alias_name_ownership)

            expect do
                Rake::Task["are_search:check_all_models"].invoke
            end.to output(
                /Article: invalid setting/,
            ).to_stdout
        end
    end

    describe "are_search:clean_up_all" do
        it "1 index の clean up が失敗しても残り index を処理する" do
            allow(article_index_target)
                .to receive(:are_search_clean_up)
                .and_raise(RuntimeError, "delete failed")

            allow(document_index_target)
                .to receive(:are_search_clean_up)
                .and_return(
                    result:             :success,
                    message:            '',
                    stop_phase:         nil,
                    done_phases:        [:lock_index, :acquire_index_target_sync_lock, :check_alias, :delete_indexes],
                    delete_index_names: [],
                )

            expect do
                Rake::Task["are_search:clean_up_all"].invoke
            end.to output(
                "[AreSearch] clean_up failed: test__articles__default RuntimeError: delete failed\n" \
                "[AreSearch] clean_up done: test__documents__default\n",
            ).to_stdout
        end

        it "index 操作が許可されていない場合は例外を再送出する" do
            allow(article_index_target)
                .to receive(:are_search_clean_up)
                .and_raise(AreSearch::IndexOperationViolation, "not allowed")

            expect(document_index_target)
                .not_to receive(:are_search_clean_up)

            expect do
                Rake::Task["are_search:clean_up_all"].invoke
            end.to raise_error(AreSearch::IndexOperationViolation, "not allowed")
        end
    end

    describe "are_search:check_index_status" do
        it "Elasticsearch 状態の取得に失敗しても sync lock と lock を出力して次のindexへ進む" do
            allow(AreSearch::EsAdapter)
                .to receive(:indices_get_alias)
                .and_return({})

            allow(AreSearch::EsAdapter)
                .to receive(:physical_indices_for_alias)
                .and_return({})

            allow(AreSearch::EsAdapter)
                .to receive(:alias_named_physical_index)
                .and_return({})

            allow(AreSearch::EsAdapter)
                .to receive(:indices_get_alias)
                .with(index_alias_name: "test__articles__default")
                .and_raise(RuntimeError, "es down")

            expected_output = Regexp.new(
                "index status: test__articles__default.*sync lock:\\s+none.*" \
                    "elasticsearch: failed RuntimeError: es down.*index status: test__documents__default",
                Regexp::MULTILINE,
            )

            expect do
                Rake::Task["are_search:check_index_status"].invoke
            end.to output(expected_output).to_stdout
        end
    end

    describe "are_search:reindex_all_for_es_version_up" do
        let(:indices) { double("indices") }
        let(:client) { double("client", indices: indices) }

        before do
            allow(AreSearch).to receive(:client).and_return(client)
            allow(AreSearch).to receive(:index_prefix).and_return("test")
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
                .to receive(:physical_index_names_by_alias)
                .with("test__articles__default")
                .and_return(["test__articles__default__2026_07_10_00_00_00_000000"])

            allow(AreSearch::IndexManager)
                .to receive(:physical_index_names_by_alias)
                .with("test__documents__default")
                .and_return(["test__documents__default__2026_07_10_00_00_00_000000"])

            allow($stdin).to receive(:gets).and_return("n\n")

            expect(article_index_target).not_to receive(:are_search_reindex)
            expect(document_index_target).not_to receive(:are_search_reindex)

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

        it "reindexで失敗IDが返された場合は対象index名を含めてエラーにする" do
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
                .to receive(:physical_index_names_by_alias)
                .with("test__articles__default")
                .and_return(["test__articles__default__2026_07_10_00_00_00_000000"])

            allow(AreSearch::IndexManager)
                .to receive(:physical_index_names_by_alias)
                .with("test__documents__default")
                .and_return(["test__documents__default__2026_07_10_00_00_00_000000"])

            allow($stdin).to receive(:gets).and_return("y\n")

            expect(article_index_target)
                .to receive(:are_search_reindex)
                .with(stage_position: :last)
                .and_return(
                    result:      :not_success,
                    message:     "bulk 投入に失敗した ID があるため alias を切り替えませんでした",
                    failed_ids:  [123],
                    stop_phase:  :index_to_new_index,
                    done_phases: [:create_new_index],
                )

            expect(document_index_target)
                .not_to receive(:are_search_reindex)

            expect do
                Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
            end.to raise_error(
                AreSearch::Error,
                /reindex に失敗したデータがあります: test__articles__default.*failed_ids.*123/,
            )
        end


        it "reindex結果が失敗なら停止段階を含めてエラーにする" do
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
                .to receive(:physical_index_names_by_alias)
                .with("test__articles__default")
                .and_return(["test__articles__default__2026_07_10_00_00_00_000000"])

            allow(AreSearch::IndexManager)
                .to receive(:physical_index_names_by_alias)
                .with("test__documents__default")
                .and_return(["test__documents__default__2026_07_10_00_00_00_000000"])

            allow($stdin).to receive(:gets).and_return("y\n")

            expect(article_index_target)
                .to receive(:are_search_reindex)
                .with(stage_position: :last)
                .and_return(
                    result:      :not_success,
                    message:     "インデックスの切り替えに失敗しました。",
                    failed_ids:  [],
                    stop_phase:  :switch_alias,
                    done_phases: [:index_to_new_index],
                )

            expect(document_index_target)
                .not_to receive(:are_search_reindex)

            expect do
                Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
            end.to raise_error(
                AreSearch::Error,
                "[AreSearch] reindex を実行できませんでした: " \
                    "test__articles__default stopped at switch_alias",
            )
        end
    end
end
