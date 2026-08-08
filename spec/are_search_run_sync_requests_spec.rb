# frozen_string_literal: true

require "spec_helper"
require "rake"
require "active_support/core_ext/numeric/time"

RSpec.describe "are_search run sync requests task" do
    let(:article_model) do
        class_double(
            "Article",
            name: "Article",
        )
    end

    let(:document_model) do
        class_double(
            "Document",
            name: "Document",
        )
    end

    let(:application) { double("application", eager_load!: true) }

    let(:article_index_target) do
        double("article_index_target", index_target_name: :default)
    end

    let(:document_index_target) do
        double("document_index_target", index_target_name: :default)
    end

    around do |example|
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        AreSearch.rake_operation_enabled = true

        example.run
    ensure
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
    end

    before do
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load File.expand_path(
            "../lib/generators/are_search/templates/are_search_run_sync_requests.rake",
            __dir__,
        )

        allow(Rails)
            .to receive(:application)
            .and_return(application)

        allow(ActiveRecord::Base)
            .to receive(:descendants)
            .and_return([article_model, document_model])

        allow(article_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(document_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(article_model)
            .to receive(:are_search_index_targets)
            .and_return([article_index_target])
        allow(article_model)
            .to receive(:are_search_get_all_sync_stage_names)
            .with(:default)
            .and_return(["default", "with_external_file"])

        allow(document_model)
            .to receive(:are_search_index_targets)
            .and_return([document_index_target])
        allow(document_model)
            .to receive(:are_search_get_all_sync_stage_names)
            .with(:default)
            .and_return(["default"])

        allow(AreSearch)
            .to receive(:sync_request_delay)
            .and_return(120)

        allow(AreSearch)
            .to receive(:max_sync_try_count)
            .and_return(3)

        allow(AreSearch)
            .to receive(:sync_request_process_hang_wait)
            .and_return(1800)

        allow(AreSearch)
            .to receive(:max_force_try_count)
            .and_return(2)
    end

    after do
        Rake.application = Rake::Application.new
    end

    # 生成rake taskの対象scopeを確認するための同期要求を作成する。
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

    it "rake操作が許可されていない場合は同期処理を開始しない" do
        AreSearch.rake_operation_enabled = false

        expect(Rails.application)
            .not_to receive(:eager_load!)

        expect(AreSearch::SyncRequestRunner)
            .not_to receive(:run)

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke("default")
        end.to raise_error(
            AreSearch::RakeOperationViolation,
            /rake_operation_enabled が false/,
        )
    end

    it "stageを指定しなければ拒否する" do
        expect(Rails.application)
            .not_to receive(:eager_load!)

        expect(AreSearch::SyncRequestRunner)
            .not_to receive(:run)

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke
        end.to raise_error(
            ArgumentError,
            "sync_stage_names を1件以上指定してください",
        )
    end

    it "どのSearchableモデルにも定義されていないstageは拒否する" do
        expect(AreSearch::SyncRequestRunner)
            .not_to receive(:run)

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke("missing_stage")
        end.to raise_error(
            ArgumentError,
            '定義されていない sync_stage_name があります: ["missing_stage"]',
        )
    end

    it "指定stageと運用条件で作成したscopeをRunnerへ渡す" do
        now = Time.zone.now
        old_time = now - 3600
        new_time = now - 60

        normal_default = create_sync_request(
            ar_instance_key:     "1",
            sync_stage_name:          "default",
            request_sequence_at: old_time,
        )
        normal_external = create_sync_request(
            ar_instance_key:     "2",
            sync_stage_name:          "with_external_file",
            request_sequence_at: old_time,
        )
        create_sync_request(
            ar_instance_key:     "3",
            sync_stage_name:          "other",
            request_sequence_at: old_time,
        )
        create_sync_request(
            ar_instance_key:     "4",
            sync_stage_name:          "default",
            request_sequence_at: new_time,
        )
        create_sync_request(
            ar_instance_key:     "5",
            sync_stage_name:          "default",
            request_sequence_at: old_time,
            sync_try_count:   3,
            last_sync_try_at: old_time + 10,
        )

        force_default = create_sync_request(
            ar_instance_key:     "6",
            sync_stage_name:          "default",
            request_sequence_at: old_time,
            processing_token:    "job-token-1",
            processing_at:       old_time,
            force_try_count: 0,
        )
        force_external = create_sync_request(
            ar_instance_key:     "7",
            sync_stage_name:          "with_external_file",
            request_sequence_at: old_time,
            processing_token:    "job-token-2",
            processing_at:       old_time,
            force_try_count: 1,
        )
        create_sync_request(
            ar_instance_key:     "8",
            sync_stage_name:          "other",
            request_sequence_at: old_time,
            processing_token:    "job-token-3",
            processing_at:       old_time,
            force_try_count: 0,
        )
        processing_recent = create_sync_request(
            ar_instance_key:     "9",
            sync_stage_name:          "default",
            request_sequence_at: old_time,
            processing_token:    "job-token-4",
            processing_at:       new_time,
            force_try_count: 0,
        )
        force_try_limit_reached = create_sync_request(
            ar_instance_key:     "10",
            sync_stage_name:          "default",
            request_sequence_at: old_time,
            processing_token:    "job-token-5",
            processing_at:       old_time,
            force_try_count: 2,
        )

        expect(AreSearch::SyncRequestRunner)
            .to receive(:run) do |models:, normal_scope:, force_scope:, processing_token:, lock_file_path:|
                expect(models).to eq([article_model, document_model])
                expect(normal_scope.order(:id).pluck(:id)).to eq([
                    normal_default.id,
                    normal_external.id,
                    force_default.id,
                    force_external.id,
                    processing_recent.id,
                    force_try_limit_reached.id,
                ])
                expect(force_scope.order(:id).pluck(:id)).to eq([
                    force_default.id,
                    force_external.id,
                ])
                expect(processing_token).to eq("rake task")
                expect(lock_file_path).to eq(AreSearch.sync_lock_file_path)

                {
                    normal_count: 2,
                    force_count:  1,
                }
            end

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke(
                "default",
                "with_external_file",
            )
        end.to output(
            /sync_stage_names=\["default", "with_external_file"\].*通常 2 件 強制 1 件/m,
        ).to_stdout
    end

    it "Runnerがlockを取得できなければスキップを表示する" do
        allow(AreSearch::SyncRequestRunner)
            .to receive(:run)
            .and_return(nil)

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke("default")
        end.to output(
            /run_sync_requests は別プロセスが実行中のためスキップしました/,
        ).to_stdout
    end
end
