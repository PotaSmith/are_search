# frozen_string_literal: true

require "spec_helper"
require_relative "../lib/are_search/rake_utils"
require "rake"
require "active_support/core_ext/numeric/time"
require "tmpdir"
require "fileutils"
require "action_mailer"
require "rails/generators"
require "generators/are_search/sample_generator"

RSpec.describe AreSearch::RakeUtils::ReindexAllForEsVersionUp do
    describe ".searchable_index_targets_for_reindex" do
        let(:application) { double("application", eager_load!: true) }
        let(:upper_target) do
            double(
                "upper_target",
                are_search_index_alias_name: "test__articles__default",
            )
        end
        let(:lower_target) do
            double(
                "lower_target",
                are_search_index_alias_name: "test__articles__default",
            )
        end
        let(:other_target) do
            double(
                "other_target",
                are_search_index_alias_name: "test__documents__default",
            )
        end
        let(:upper_model) do
            class_double(
                "Article",
                are_search_index_targets: [upper_target],
            )
        end
        let(:lower_model) do
            class_double(
                "SpecialArticle",
                are_search_index_targets: [lower_target],
            )
        end
        let(:other_model) do
            class_double(
                "Document",
                are_search_index_targets: [other_target],
            )
        end

        before do
            allow(Rails)
                .to receive(:application)
                .and_return(application)

            allow(ActiveRecord::Base)
                .to receive(:descendants)
                .and_return([
                    lower_model,
                    other_model,
                    upper_model,
                ])

            [
                upper_model,
                lower_model,
                other_model,
            ].each do |model|
                allow(model)
                    .to receive(:include?)
                    .with(AreSearch::Searchable)
                    .and_return(true)

                allow(model)
                    .to receive(:<)
                    .and_return(nil)
            end

            allow(lower_model)
                .to receive(:<)
                .with(upper_model)
                .and_return(true)
        end

        it "Searchable の継承系統ごとに最も上位のモデルの index target を返す" do
            expect(lower_model)
                .not_to receive(:are_search_index_targets)

            result = described_class.searchable_index_targets_for_reindex

            expect(result).to eq([
                other_target,
                upper_target,
            ])
        end

        it "独立した上位モデルのindex名が重複していれば拒否する" do
            allow(other_model)
                .to receive(:are_search_index_targets)
                .and_return([upper_target])

            expect do
                described_class.searchable_index_targets_for_reindex
            end.to raise_error(
                AreSearch::Error,
                "[AreSearch] reindex 対象の index が複数の上位モデルで重複しています: " \
                    "test__articles__default",
            )
        end
    end
end

RSpec.describe AreSearch::RakeUtils::CheckAllModels do
    describe ".validate_searchable_index_alias_name_ownership" do
        let(:application) { double("application", eager_load!: true) }
        let(:shared_target) do
            double(
                "shared_target",
                are_search_index_alias_name: "test__articles__default",
            )
        end
        let(:other_target) do
            double(
                "other_target",
                are_search_index_alias_name: "test__documents__default",
            )
        end
        let(:article_model) do
            class_double(
                "Article",
                name:                     "Article",
                are_search_index_targets: [shared_target],
            )
        end
        let(:sub_article_model) do
            class_double(
                "SubArticle",
                name:                     "SubArticle",
                are_search_index_targets: [shared_target],
            )
        end
        let(:sub_sub_article_model) do
            class_double(
                "SubSubArticle",
                name:                     "SubSubArticle",
                are_search_index_targets: [shared_target],
            )
        end
        let(:sibling_article_model) do
            class_double(
                "SiblingArticle",
                name:                     "SiblingArticle",
                are_search_index_targets: [shared_target],
            )
        end
        let(:document_model) do
            class_double(
                "Document",
                name:                     "Document",
                are_search_index_targets: [other_target],
            )
        end

        before do
            allow(Rails)
                .to receive(:application)
                .and_return(application)

            allow(ActiveRecord::Base)
                .to receive(:descendants)
                .and_return([
                    sub_sub_article_model,
                    sibling_article_model,
                    sub_article_model,
                    document_model,
                    article_model,
                ])

            [
                article_model,
                sub_article_model,
                sub_sub_article_model,
                sibling_article_model,
                document_model,
            ].each do |model|
                allow(model)
                    .to receive(:include?)
                    .with(AreSearch::Searchable)
                    .and_return(true)

                allow(model)
                    .to receive(:<)
                    .and_return(nil)
            end

            allow(sub_article_model)
                .to receive(:<)
                .with(article_model)
                .and_return(true)

            allow(sub_sub_article_model)
                .to receive(:<)
                .with(article_model)
                .and_return(true)

            allow(sub_sub_article_model)
                .to receive(:<)
                .with(sub_article_model)
                .and_return(true)

            allow(sibling_article_model)
                .to receive(:<)
                .with(article_model)
                .and_return(true)
        end

        it "同じ Searchable 祖先を持つ複数階層と兄弟モデルの同名 index を許可する" do
            errors = []

            result = described_class.validate_searchable_index_alias_name_ownership(
                errors,
            )

            expect(result).to eq(true)
            expect(errors).to eq([])
        end

        it "別の継承系統が同じ index 名を持つ場合はエラーにする" do
            allow(document_model)
                .to receive(:are_search_index_targets)
                .and_return([shared_target])

            errors = []

            result = described_class.validate_searchable_index_alias_name_ownership(
                errors,
            )

            expect(result).to eq(false)
            expect(errors).to eq([
                "継承関係のないモデルが同じ index を使用しています: " \
                    "test__articles__default: Article, Document",
            ])
        end
    end

    describe ".model_check" do
        around do |example|
            original_searchable_class_setting = AreSearch.searchable_class_setting
            AreSearch.searchable_class_setting = {
                "ModelCheckParent" => {
                    default: {
                        settings: { max_result_window: 2_000 },
                        mappings: {},
                        properties_method: :default_properties,
                        indexable_method: :default_indexable?,
                        stages: {
                            "default" => {
                                data_method: :default_search_data,
                                enqueue: true,
                                after_commit: true,
                            },
                        },
                    },
                },
            }

            example.run
        ensure
            AreSearch.searchable_class_setting = original_searchable_class_setting
        end

        def build_model_check_parent_class
            Class.new(ActiveRecord::Base) do
                self.abstract_class = true

                include AreSearch::Searchable

                def self.default_properties
                    {
                        title: { type: "text" },
                    }
                end

                def default_indexable?
                    true
                end

                def default_search_data
                    {
                        title: "hello",
                    }
                end
            end
        end

        it "STI 子クラスが properties_method の対象メソッドを定義していればエラーにする" do
            parent_model = build_model_check_parent_class
            child_model = Class.new(parent_model) do
                self.abstract_class = true

                def self.default_properties
                    {
                        title: { type: "text" },
                    }
                end
            end

            stub_const("ModelCheckParent", parent_model)
            stub_const("ModelCheckChild", child_model)

            errors = []

            described_class.model_check(child_model, errors)

            expect(errors).to eq([
                "ModelCheckChild: properties_method に指定された default_properties は " \
                    "Searchable を include した上位クラスで定義してください。",
            ])
        end

        it "STI 子クラスが are_search_ar_table_name を定義していればエラーにする" do
            parent_model = build_model_check_parent_class
            child_model = Class.new(parent_model) do
                self.abstract_class = true

                def self.are_search_ar_table_name
                    "child_articles"
                end
            end

            stub_const("ModelCheckParent", parent_model)
            stub_const("ModelCheckChild", child_model)

            errors = []

            described_class.model_check(child_model, errors)

            expect(errors).to eq([
                "ModelCheckChild: are_search_ar_table_name は Searchable を include した上位クラスで定義してください。",
            ])
        end

        it "STI 子クラスが properties_method の対象メソッドを継承しているだけならエラーにしない" do
            parent_model = build_model_check_parent_class
            child_model = Class.new(parent_model) do
                self.abstract_class = true
            end

            stub_const("ModelCheckParent", parent_model)
            stub_const("ModelCheckChild", child_model)

            errors = []

            described_class.model_check(child_model, errors)

            expect(errors).to eq([])
        end
    end
end

RSpec.describe AreSearch::Generators::SampleGenerator do

    it "rakeとBulkIndexerのサンプルをtmp配下へ生成する" do
        Dir.mktmpdir("are_search_sample_generator") do |destination_root|
            described_class.start([], destination_root: destination_root)

            sample_dir = File.join(
                destination_root,
                "tmp/are_search/sample",
            )

            run_sync_sample_path = File.join(
                sample_dir,
                "are_search_run_sync_requests.rake.sample",
            )
            sync_limit_alert_sample_path = File.join(
                sample_dir,
                "are_search_sync_limit_alert.rake.sample",
            )
            sync_request_boundary_sample_path = File.join(
                sample_dir,
                "are_search_sync_request_boundary.rake.sample",
            )
            ruby_sample_path = File.join(
                sample_dir,
                "are_search_bulk_index.rb.sample",
            )
            shell_sample_path = File.join(
                sample_dir,
                "are_search_bulk_index.sh.sample",
            )

            expect(File.file?(run_sync_sample_path)).to eq(true)
            expect(File.file?(sync_limit_alert_sample_path)).to eq(true)
            expect(File.file?(sync_request_boundary_sample_path)).to eq(true)
            expect(File.file?(ruby_sample_path)).to eq(true)
            expect(File.file?(shell_sample_path)).to eq(true)

            run_sync_sample = File.read(run_sync_sample_path)
            sync_limit_alert_sample = File.read(sync_limit_alert_sample_path)
            sync_request_boundary_sample = File.read(sync_request_boundary_sample_path)
            ruby_sample = File.read(ruby_sample_path)
            shell_sample = File.read(shell_sample_path)

            expect(run_sync_sample).to include(
                "task :run_sync_requests",
            )
            expect(run_sync_sample).to include(
                "定義されていない sync_stage_name があります",
            )
            expect(sync_limit_alert_sample).to include(
                "task sync_limit_alert: :environment",
            )
            expect(sync_request_boundary_sample).to include(
                "task delete_sync_stage_all_sync_requests: :environment",
            )
            expect(sync_request_boundary_sample).to include(
                "task set_sync_request_boundary: :environment",
            )
            expect(sync_request_boundary_sample).to include(
                "task run_sync_request_before_boundary: :environment",
            )
            expect(sync_request_boundary_sample).to include(
                "task clear_sync_request_boundary: :environment",
            )
            expect(ruby_sample).to include(
                'ENV.fetch("ARE_SEARCH_BULK_RESULT_DIR")',
            )
            expect(ruby_sample).to include(
                "index_target.are_search_bulk_index(",
            )
            expect(shell_sample).to include(
                'exec bundle exec rails runner "$RUBY_SCRIPT"',
            )
            expect(shell_sample).to include(
                'RESULT_DIR="/path/to/persistent/are_search/bulk/article_new_version"',
            )

            max_bulk_count = ruby_sample.match(
                /max_bulk_count\s*=\s*(\d+)/,
            )[1].to_i
            max_fail_count = ruby_sample.match(
                /max_fail_count\s*=\s*(\d+)/,
            )[1].to_i

            expect(max_bulk_count).to be <= max_fail_count
            expect(max_fail_count).to be <= (
                AreSearch::BulkIndexer::MAX_RECOVER_COUNT / 2
            )
        end
    end
end

RSpec.describe AreSearch::Generators::SampleGenerator do

    it "BulkIndexerのRubyとshellサンプルをtmp配下へ生成する" do
        Dir.mktmpdir("are_search_bulk_sample_generator") do |destination_root|
            described_class.start([], destination_root: destination_root)

            ruby_sample_path = File.join(
                destination_root,
                "tmp/are_search/sample/are_search_bulk_index.rb.sample",
            )
            shell_sample_path = File.join(
                destination_root,
                "tmp/are_search/sample/are_search_bulk_index.sh.sample",
            )

            expect(File.file?(ruby_sample_path)).to eq(true)
            expect(File.file?(shell_sample_path)).to eq(true)

            ruby_sample = File.read(ruby_sample_path)
            shell_sample = File.read(shell_sample_path)

            expect(ruby_sample).to include(
                'ENV.fetch("ARE_SEARCH_BULK_RESULT_DIR")',
            )
            expect(ruby_sample).to include(
                "index_target.are_search_bulk_index(",
            )
            expect(shell_sample).to include(
                'exec bundle exec rails runner "$RUBY_SCRIPT"',
            )
            expect(shell_sample).to include(
                'RESULT_DIR="/path/to/persistent/are_search/bulk/article_new_version"',
            )

            max_bulk_count = ruby_sample.match(
                /max_bulk_count\s*=\s*(\d+)/,
            )[1].to_i
            max_fail_count = ruby_sample.match(
                /max_fail_count\s*=\s*(\d+)/,
            )[1].to_i

            expect(max_bulk_count).to be <= max_fail_count
            expect(max_fail_count).to be <= (
                AreSearch::BulkIndexer::MAX_RECOVER_COUNT / 2
            )
        end
    end
end

RSpec.describe "are_search sync request boundary task" do
    let(:model_class) do
        class_double(
            "SampleData",
            name: "SampleData",
        )
    end
    let(:index_target) do
        double(
            "index_target",
            are_search_index_alias_name: "test__sample_data__name",
        )
    end
    let(:application) do
        double("application", eager_load!: true)
    end

    around do |example|
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_lock_dir = AreSearch.lock_dir
        AreSearch.rake_operation_enabled = true
        AreSearch.lock_dir = "/tmp/are_search_boundary_spec"

        example.run
    ensure
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.lock_dir = original_lock_dir
    end

    before do
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        if Object.const_defined?(:AreSearchSyncRequestBoundaryTask, false)
            Object.send(:remove_const, :AreSearchSyncRequestBoundaryTask)
        end

        load File.expand_path(
            "../lib/generators/are_search/templates/are_search_sync_request_boundary.rake",
            __dir__,
        )

        stub_const("SampleData", model_class)

        allow(model_class)
            .to receive(:are_search_index_target)
            .with("name")
            .and_return(index_target)

        allow(Rails)
            .to receive(:application)
            .and_return(application)

        allow(ActiveRecord::Base)
            .to receive(:descendants)
            .and_return([model_class])

        allow(model_class)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(index_target)
            .to receive(:are_search_find_sync_request_boundary_target!)
            .with("sample") do
                AreSearch::SyncRequestBoundaryTarget.find_by(
                    index_alias_name: "test__sample_data__name",
                    sync_stage_name:  "sample",
                )
            end

        allow(index_target)
            .to receive(:are_search_set_sync_request_boundary_target!)
            .with("sample") do
                AreSearch::SyncRequestBoundaryTarget.set_target!(
                    "test__sample_data__name",
                    "sample",
                )
            end

        allow(index_target)
            .to receive(:are_search_clear_sync_request_boundary_target!)
            .with("sample") do
                AreSearch::SyncRequestBoundaryTarget.where(
                    index_alias_name: "test__sample_data__name",
                    sync_stage_name:  "sample",
                ).delete_all
            end
    end

    after do
        Rake.application = Rake::Application.new
    end

    # Boundary taskの対象選択に使う同期要求を作成する。
    def create_boundary_sync_request(attrs = {})
        defaults = {
            ar_model_class_name: "SampleData",
            index_target_name:   "name",
            ar_instance_key:     "1",
            index_alias_name:    "test__sample_data__name",
            sync_stage_name:     "sample",
            request_sequence:    10,
            request_sequence_at: Time.zone.parse("2026-08-15 10:00:00"),
        }

        AreSearch::SyncRequest.create!(defaults.merge(attrs))
    end

    # 今回のbulk終了境界を作成する。
    def create_boundary_target(attrs = {})
        defaults = {
            index_alias_name:      "test__sample_data__name",
            sync_stage_name:       "sample",
            sequence_limit:        20,
            last_sync_started_at:  Time.zone.parse("2026-08-15 10:00:00"),
            last_sync_ended_at:    Time.zone.parse("2026-08-15 10:00:00"),
        }

        AreSearch::SyncRequestBoundaryTarget.create!(defaults.merge(attrs))
    end

    describe "are_search:delete_sync_stage_all_sync_requests" do
        it "対象IndexTargetとstageのSyncRequestだけを削除する" do
            target_request = create_boundary_sync_request
            other_stage_request = create_boundary_sync_request(
                ar_instance_key:  "2",
                sync_stage_name:  "default",
                request_sequence: 11,
            )
            other_index_request = create_boundary_sync_request(
                ar_instance_key:  "3",
                index_alias_name: "test__sample_data__other",
                request_sequence: 12,
            )

            expect do
                Rake::Task["are_search:delete_sync_stage_all_sync_requests"].invoke
            end.to output(/sync_requestを削除しました。1件/).to_stdout

            expect(AreSearch::SyncRequest.exists?(target_request.id)).to eq(false)
            expect(AreSearch::SyncRequest.exists?(other_stage_request.id)).to eq(true)
            expect(AreSearch::SyncRequest.exists?(other_index_request.id)).to eq(true)
        end
    end

    describe "are_search:set_sync_request_boundary" do
        it "現在のrequest sequenceと時刻をBoundaryTargetへ保存する" do
            created_at = Time.zone.parse("2026-08-15 11:00:00")

            expect(AreSearch.database_specific)
                .to receive(:next_request_sequence)
                .and_return(42)
            allow(Time.zone)
                .to receive(:now)
                .and_return(created_at)

            expect do
                Rake::Task["are_search:set_sync_request_boundary"].invoke
            end.to output(/BoundaryTargetをセットしました。limit=42/).to_stdout

            boundary_target = AreSearch::SyncRequestBoundaryTarget.find_by!(
                index_alias_name: "test__sample_data__name",
                sync_stage_name:  "sample",
            )
            expect(boundary_target.sequence_limit).to eq(42)
        end

        it "既存のBoundaryTargetがある場合は例外にする" do
            boundary_target = create_boundary_target
            created_at = boundary_target.created_at

            expect(AreSearch.database_specific)
                .not_to receive(:next_request_sequence)

            expect do
                Rake::Task["are_search:set_sync_request_boundary"].invoke
            end.to raise_error(ArgumentError, "SyncRequestBoundaryTarget は既に存在します: sample")

            expect(AreSearch::SyncRequestBoundaryTarget.count).to eq(1)
            expect(boundary_target.reload.sequence_limit).to eq(20)
            expect(boundary_target.created_at).to eq(created_at)
        end
    end

    describe "are_search:clear_sync_request_boundary" do
        it "保存したBoundaryTargetを削除する" do
            boundary_target = create_boundary_target

            expect do
                Rake::Task["are_search:clear_sync_request_boundary"].invoke
            end.to output(/BoundaryTargetをクリアしました。/).to_stdout

            expect(AreSearch::SyncRequestBoundaryTarget.exists?(boundary_target.id)).to eq(false)
        end
    end

    describe "are_search:run_sync_request_before_boundary" do
        it "境界以前のSyncRequestだけを同期対象にする" do
            boundary_target = create_boundary_target
            before_boundary = create_boundary_sync_request(
                ar_instance_key:  "1",
                request_sequence: 20,
            )
            after_boundary = create_boundary_sync_request(
                ar_instance_key:     "2",
                request_sequence:    21,
                request_sequence_at: Time.zone.parse("2026-08-15 10:10:00"),
            )
            create_boundary_sync_request(
                ar_instance_key:     "3",
                sync_stage_name:     "default",
                request_sequence:    10,
                request_sequence_at: Time.zone.parse("2026-08-15 10:00:00"),
            )

            run_at = Time.zone.parse("2026-08-15 11:00:00")
            allow(Time.zone)
                .to receive(:now)
                .and_return(run_at)
            allow($stdin)
                .to receive(:gets)
                .and_return("y\n")

            expect(AreSearch::SyncRequestRunner)
                .to receive(:run) do |models:, normal_scope:, force_scope:, processing_token:, lock_file_path:|
                    expect(models).to eq([model_class])
                    expect(normal_scope.order(:id).pluck(:id)).to eq([before_boundary.id])
                    expect(normal_scope.exists?(after_boundary.id)).to eq(false)
                    expect(force_scope.count).to eq(0)
                    expect(processing_token).to eq(AreSearch::SyncRequest::RAKE_PROCESSING_TOKEN)
                    expect(lock_file_path).to eq(AreSearch.sync_runner_lock_file_path)

                    {
                        normal_count: 1,
                        force_count:  0,
                    }
                end

            expect do
                Rake::Task["are_search:run_sync_request_before_boundary"].invoke
            end.to output(/Boundary同期対象 実行前 1件.*Boundary同期対象 実行後 1件/m).to_stdout

            boundary_target.reload
            expect(boundary_target.last_sync_started_at).to eq(run_at)
            expect(boundary_target.last_sync_ended_at).to eq(run_at)
        end

        it "境界後の新しい要求へupsertされた場合は同期対象にしない" do
            create_boundary_target
            sync_request = create_boundary_sync_request(
                request_sequence:    10,
                request_sequence_at: Time.zone.parse("2026-08-15 09:00:00"),
            )
            new_request_sequence_at = Time.zone.parse("2026-08-15 10:10:00")

            AreSearch::SyncRequest.upsert(
                {
                    ar_model_class_name: "SampleData",
                    index_target_name:   "name",
                    ar_instance_key:     "1",
                    index_alias_name:    "test__sample_data__name",
                    sync_stage_name:     "sample",
                    request_sequence:    21,
                    request_sequence_at: new_request_sequence_at,
                },
                unique_by: [:index_alias_name, :sync_stage_name, :ar_instance_key],
            )

            sync_request.reload
            expect(sync_request.request_sequence).to eq(21)
            expect(sync_request.request_sequence_at).to eq(new_request_sequence_at)

            expect(AreSearch::SyncRequestRunner)
                .not_to receive(:run)

            expect do
                Rake::Task["are_search:run_sync_request_before_boundary"].invoke
            end.to output(/Boundary同期対象 実行前 0件/).to_stdout
        end

        it "同期確認でy以外なら同期を開始しない" do
            create_boundary_target
            create_boundary_sync_request

            allow($stdin)
                .to receive(:gets)
                .and_return("n\n")

            expect(AreSearch::SyncRequestRunner)
                .not_to receive(:run)

            expect do
                Rake::Task["are_search:run_sync_request_before_boundary"].invoke
            end.to output(/同期を実行しますか？.*Boundary同期をキャンセルしました。/m).to_stdout
        end

        it "BoundaryTargetが無ければ同期を開始しない" do
            expect(AreSearch::SyncRequestRunner)
                .not_to receive(:run)

            expect do
                Rake::Task["are_search:run_sync_request_before_boundary"].invoke
            end.to output(/SyncRequestBoundaryTargetがありません/).to_stdout
        end
    end
end

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
        allow(article_index_target)
            .to receive(:are_search_sync_stage_names)
            .and_return(["default", "with_external_file"])

        allow(document_model)
            .to receive(:are_search_index_targets)
            .and_return([document_index_target])
        allow(document_index_target)
            .to receive(:are_search_sync_stage_names)
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
                expect(lock_file_path).to eq(AreSearch.sync_runner_lock_file_path)

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
            /run_sync_requests は別の処理が実行中のためスキップしました/,
        ).to_stdout
    end
end

RSpec.describe "are_search sync limit alert task" do
    before do
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        if Object.const_defined?(:AreSearchSyncLimitAlertTask)
            Object.send(:remove_const, :AreSearchSyncLimitAlertTask)
        end

        load File.expand_path(
            "../lib/generators/are_search/templates/are_search_sync_limit_alert.rake",
            __dir__,
        )
    end

    after do
        Rake.application = Rake::Application.new
    end

    # 通知条件の検査に使う同期要求を作成する。
    def create_sync_request(attrs = {})
        defaults = {
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "1",
            index_alias_name:          "test__articles__default",
            sync_stage_name:          "default",
            request_sequence:    10,
            request_sequence_at: Time.zone.now,
            sync_try_count:      0,
            callback_try_count:  0,
            last_error:          nil,
            last_error_at:       nil,
        }

        AreSearch::SyncRequest.create!(defaults.merge(attrs))
    end

    it "通知詳細にstageと同期処理の時刻を含める" do
        request_sequence_at = Time.zone.parse("2026-08-03 01:00:00")
        last_sync_try_at = Time.zone.parse("2026-08-03 01:01:00")
        last_callback_try_at = Time.zone.parse("2026-08-03 01:02:00")
        last_completed_at = Time.zone.parse("2026-08-03 00:30:00")
        last_error_at = Time.zone.parse("2026-08-03 01:03:00")

        sync_request = create_sync_request(
            sync_stage_name:       "with_external_file",
            request_sequence_at:   request_sequence_at,
            sync_try_count:        3,
            last_sync_try_at:      last_sync_try_at,
            callback_try_count:    2,
            last_callback_try_at:  last_callback_try_at,
            last_completed_at:     last_completed_at,
            last_error:            "timeout",
            last_error_at:         last_error_at,
        )

        lines = []
        mailer = AreSearchSyncLimitAlertTask::Mailer.new

        mailer.send(:append_sync_request, lines, sync_request)

        body = lines.join("\n")
        expect(body).to include("sync_stage_name :      with_external_file")
        expect(body).to include("request_sequence_at :  #{request_sequence_at}")
        expect(body).to include("last_sync_try_at :     #{last_sync_try_at}")
        expect(body).to include("callback_try_count :   2")
        expect(body).to include("last_callback_try_at : #{last_callback_try_at}")
        expect(body).to include("last_completed_at :    #{last_completed_at}")
        expect(body).to include("last_error_at :        #{last_error_at}")
        expect(body).not_to include("last_error :")
        expect(body).not_to include("timeout")
    end

    it "sync_try_countは閾値未満を除外して閾値を通知する" do
        below_request = create_sync_request(
            ar_instance_key: "1",
            sync_try_count: AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD - 1,
        )
        boundary_request = create_sync_request(
            ar_instance_key: "2",
            sync_try_count: AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD,
        )
        delivery = double("delivery")

        expect(AreSearchSyncLimitAlertTask::Mailer)
            .to receive(:sync_limit_alert) do |sync_requests, force_requests, stuck_requests|
                expect(sync_requests.map(&:id)).to eq([boundary_request.id])
                expect(sync_requests).not_to include(below_request)
                expect(force_requests).to eq([])
                expect(stuck_requests).to eq([])

                delivery
            end
        expect(delivery).to receive(:deliver_now)

        Rake::Task["are_search:sync_limit_alert"].invoke
    end

    it "force_try_countは閾値未満を除外して閾値を通知する" do
        below_request = create_sync_request(
            ar_instance_key: "1",
            force_try_count: AreSearchSyncLimitAlertTask::ALERT_FORCE_TRY_THRESHOLD - 1,
        )
        boundary_request = create_sync_request(
            ar_instance_key: "2",
            force_try_count: AreSearchSyncLimitAlertTask::ALERT_FORCE_TRY_THRESHOLD,
        )
        delivery = double("delivery")

        expect(AreSearchSyncLimitAlertTask::Mailer)
            .to receive(:sync_limit_alert) do |sync_requests, force_requests, stuck_requests|
                expect(sync_requests).to eq([])
                expect(force_requests.map(&:id)).to eq([boundary_request.id])
                expect(force_requests).not_to include(below_request)
                expect(stuck_requests).to eq([])

                delivery
            end
        expect(delivery).to receive(:deliver_now)

        Rake::Task["are_search:sync_limit_alert"].invoke
    end

    it "last_error_atは残留時間の境界を含み境界より新しい要求を除外する" do
        now = Time.zone.parse("2026-08-10 18:00:00")
        border_time = now - AreSearchSyncLimitAlertTask::ALERT_STUCK_ERROR_WAIT
        recent_request = create_sync_request(
            ar_instance_key: "1",
            last_error:      "recent error",
            last_error_at:   border_time + 1,
        )
        boundary_request = create_sync_request(
            ar_instance_key: "2",
            last_error:      "boundary error",
            last_error_at:   border_time,
        )
        delivery = double("delivery")

        allow(Time.zone)
            .to receive(:now)
            .and_return(now)
        expect(AreSearchSyncLimitAlertTask::Mailer)
            .to receive(:sync_limit_alert) do |sync_requests, force_requests, stuck_requests|
                expect(sync_requests).to eq([])
                expect(force_requests).to eq([])
                expect(stuck_requests.map(&:id)).to eq([boundary_request.id])
                expect(stuck_requests).not_to include(recent_request)

                delivery
            end
        expect(delivery).to receive(:deliver_now)

        Rake::Task["are_search:sync_limit_alert"].invoke
    end

    it "3種類の通知条件に別々の要求が該当する場合は3種類をまとめて通知する" do
        sync_request = create_sync_request(
            ar_instance_key: "1",
            sync_try_count: AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD,
        )
        force_request = create_sync_request(
            ar_instance_key: "2",
            force_try_count: AreSearchSyncLimitAlertTask::ALERT_FORCE_TRY_THRESHOLD,
        )
        stuck_request = create_sync_request(
            ar_instance_key: "3",
            last_error:      "stuck error",
            last_error_at:   Time.zone.now - AreSearchSyncLimitAlertTask::ALERT_STUCK_ERROR_WAIT - 1,
        )
        delivery = double("delivery")

        expect(AreSearchSyncLimitAlertTask::Mailer)
            .to receive(:sync_limit_alert) do |sync_requests, force_requests, stuck_requests|
                expect(sync_requests.map(&:id)).to eq([sync_request.id])
                expect(force_requests.map(&:id)).to eq([force_request.id])
                expect(stuck_requests.map(&:id)).to eq([stuck_request.id])

                delivery
            end
        expect(delivery).to receive(:deliver_now)

        expect do
            Rake::Task["are_search:sync_limit_alert"].invoke
        end.to output(/sync_request 3件/).to_stdout
    end

    it "複数の通知条件に該当する同じ要求は合計件数で重複しない" do
        sync_request = create_sync_request(
            sync_try_count: 100,
            force_try_count:   5,
            last_error:        "timeout",
            last_error_at:     Time.zone.now - 7201,
        )

        mail = AreSearchSyncLimitAlertTask::Mailer.new.sync_limit_alert(
            [sync_request],
            [sync_request],
            [sync_request],
        )

        expect(mail.subject).to include("(1件)")
        expect(mail.body.encoded).to include("合計件数: 1")
    end

    it "長期残留判定はupdated_atではなくlast_error_atを使う" do
        now = Time.zone.now
        old_error = create_sync_request(
            ar_instance_key: "1",
            last_error:      "old error",
            last_error_at:   now - 7201,
        )
        old_error.update_columns(updated_at: now)

        recent_error = create_sync_request(
            ar_instance_key: "2",
            last_error:      "recent error",
            last_error_at:   now - 60,
        )
        recent_error.update_columns(updated_at: now - 10_000)

        delivery = double("delivery")

        expect(AreSearchSyncLimitAlertTask::Mailer)
            .to receive(:sync_limit_alert) do |sync_requests, force_requests, stuck_requests|
                expect(sync_requests).to eq([])
                expect(force_requests).to eq([])
                expect(stuck_requests.map(&:id)).to eq([old_error.id])

                delivery
            end

        expect(delivery)
            .to receive(:deliver_now)

        Rake::Task["are_search:sync_limit_alert"].invoke
    end
end
