# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch large reindex migration integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_rake_application = Rake.application

        @base_index_mapping = DocumentFirst.are_search_index_mappings.fetch(:default)
        @original_document_first_index_data =
            DocumentFirst.instance_method(:are_search_index_data)
        replace_document_first_index_data

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        clear_are_search_integration_records
        delete_document_first_target_index(:new_version)

        example.run
    ensure
        if @original_document_first_index_data
            DocumentFirst.send(
                :define_method,
                :are_search_index_data,
                @original_document_first_index_data,
            )
        end

        if @base_index_mapping
            reset_document_first_index_targets
            delete_document_first_target_index(:new_version)
            rebuild_empty_document_first_index
            reset_document_first_index_targets
        end

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        Rake.application = original_rake_application
    end

    # 指定targetとstage構成をDocumentFirstへ適用し、IndexTargetのキャッシュを作り直す。
    def apply_document_first_definition(
        target_names:,
        all_sync_stage_names:,
        enqueue_sync_stage_names:,
        after_commit_sync_stage_names:
    )
        mappings = {}
        target_names.each do |index_target_name|
            mappings[index_target_name] = @base_index_mapping
        end

        allow(DocumentFirst)
            .to receive(:are_search_index_mappings)
            .and_return(mappings)
        allow(DocumentFirst)
            .to receive(:are_search_all_sync_stage_names)
            .and_return(all_sync_stage_names)
        allow(DocumentFirst)
            .to receive(:are_search_sync_stage_names_on_enqueue)
            .and_return(enqueue_sync_stage_names)
        allow(DocumentFirst)
            .to receive(:are_search_sync_stage_names_on_after_commit)
            .and_return(after_commit_sync_stage_names)

        reset_document_first_index_targets
    end

    # DocumentFirstとSTI子クラスのIndexTargetキャッシュを現在の定義へ揃える。
    def reset_document_first_index_targets
        DocumentFirst.are_search_reset_index_targets!

        DocumentFirst.descendants.each do |model_class|
            model_class.are_search_reset_index_targets!
        end
    end

    # defaultとnew_versionの各stageで同じ完成ドキュメントを生成できるようにする。
    # SearchableValidatorがarityを検査するため、RSpec mockではなく2引数の実メソッドとして差し替える。
    def replace_document_first_index_data
        DocumentFirst.send(
            :define_method,
            :are_search_index_data,
        ) do |index_target_name, sync_stage_name|
            supported_stage = [
                [:default, "default"],
                [:new_version, "for_version_up"],
                [:new_version, "default"],
            ].include?([index_target_name, sync_stage_name])

            return {} if supported_stage == false

            {
                title:                     title,
                body:                      body,
                status:                    status,
                user_id:                   user_id,
                multi_response_both:       "first both",
                multi_response_first_only: "first only",
            }
        end
    end

    # 指定targetのalias名をモデル定義に依存せず組み立てる。
    def document_first_index_alias_name(index_target_name)
        AreSearch.join_index_name(
            AreSearch.index_prefix,
            DocumentFirst.are_search_ar_table_name,
            index_target_name,
        )
    end

    # 指定targetから生成された物理indexを削除する。
    def delete_document_first_target_index(index_target_name)
        index_alias_name = document_first_index_alias_name(index_target_name)
        physical_indices = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: index_alias_name,
        )

        physical_indices.keys.each do |physical_index_name|
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end
    end

    # 指定IndexTargetをrefreshして直後の検索から参照できるようにする。
    def refresh_index_target(index_target)
        AreSearch.client.indices.refresh(
            index: index_target.are_search_index_alias_name,
        )
    end

    # 指定targetとstageのSyncRequestを返す。
    def sync_request_for(record, index_target_name, sync_stage_name)
        AreSearch::SyncRequest.find_by(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     record.id.to_s,
            index_alias_name:    document_first_index_alias_name(index_target_name),
            sync_stage_name:     sync_stage_name,
        )
    end

    # run_sync_requestsの配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    it "巨大データ切り替え手順でbulk中の更新を差分回収して新IndexTargetへ移行する" do
        apply_document_first_definition(
            target_names: [:default],
            all_sync_stage_names: {
                default: ["default"],
            },
            enqueue_sync_stage_names: {
                default: ["default"],
            },
            after_commit_sync_stage_names: {
                default: ["default"],
            },
        )

        initial_reindex = rebuild_empty_document_first_index
        expect(initial_reindex[:result]).to eq(:success)

        first = DocumentFirst.create!(
            title:   "largereindex first",
            body:    "first body",
            status:  "published",
            user_id: 901,
        )
        second = DocumentFirst.create!(
            title:   "largereindexoldtoken",
            body:    "second body",
            status:  "published",
            user_id: 902,
        )

        default_index_target = DocumentFirst.are_search_index_target(:default)
        refresh_index_target(default_index_target)

        initial_search = search_document_first(
            "largereindexoldtoken",
            index_target: default_index_target,
        )
        expect(initial_search.records.map(&:id)).to eq([second.id])

        # 10-1: new_versionのfor_version_upをenqueueだけ行い、旧defaultは通常同期を続ける。
        apply_document_first_definition(
            target_names: [:default, :new_version],
            all_sync_stage_names: {
                default:     ["default"],
                new_version: ["for_version_up"],
            },
            enqueue_sync_stage_names: {
                default:     ["default"],
                new_version: ["for_version_up"],
            },
            after_commit_sync_stage_names: {
                default: ["default"],
            },
        )

        first.update!(title: "largereindexprebulktoken")

        pre_bulk_request = sync_request_for(
            first,
            :new_version,
            "for_version_up",
        )
        expect(pre_bulk_request).not_to eq(nil)

        default_index_target = DocumentFirst.are_search_index_target(:default)
        refresh_index_target(default_index_target)

        pre_bulk_search = search_document_first(
            "largereindexprebulktoken",
            index_target: default_index_target,
        )
        expect(pre_bulk_search.records.map(&:id)).to eq([first.id])

        # 10-2: DBにデータがある状態でnew_versionの空indexを作成する。
        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        create_index_result = new_version_index_target.are_search_create_index

        expect(create_index_result[:result]).to eq(:success)
        expect(new_version_index_target.are_search_index_alias_exists?).to eq(true)

        empty_count = AreSearch.client.count(
            index: new_version_index_target.are_search_index_alias_name,
        )
        expect(empty_count["count"]).to eq(0)

        # 10-3: bulk用dataを作った直後にDB更新を割り込ませ、古いdataをnew_versionへ送る。
        updated_during_bulk = false

        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data_for_index!)
            .and_wrap_original do |original_method, index_target, sync_stage_name|
                record = original_method.receiver
                data = original_method.call(index_target, sync_stage_name)

                if updated_during_bulk == false &&
                        record.id == second.id &&
                        index_target.index_target_name == :new_version &&
                        sync_stage_name == "for_version_up"
                    updated_during_bulk = true

                    DocumentFirst.find(second.id).update!(
                        title: "largereindexduringbulktoken",
                    )
                end

                data
            end

        Dir.mktmpdir("are_search_large_reindex_integration") do |result_dir|
            new_version_index_target.are_search_bulk_index(
                "for_version_up",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )
        end

        expect(updated_during_bulk).to eq(true)

        default_index_target = DocumentFirst.are_search_index_target(:default)
        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        refresh_index_target(default_index_target)
        refresh_index_target(new_version_index_target)

        default_after_race = search_document_first(
            "largereindexduringbulktoken",
            index_target: default_index_target,
        )
        expect(default_after_race.records.map(&:id)).to eq([second.id])

        new_version_stale = search_document_first(
            "largereindexoldtoken",
            index_target: new_version_index_target,
        )
        expect(new_version_stale.records.map(&:id)).to eq([second.id])

        new_version_before_recovery = search_document_first(
            "largereindexduringbulktoken",
            index_target: new_version_index_target,
        )
        expect(new_version_before_recovery.records).to eq([])

        during_bulk_request = sync_request_for(
            second,
            :new_version,
            "for_version_up",
        )
        expect(during_bulk_request).not_to eq(nil)

        # 10-4前半: new_versionへdefaultを追加し、移行中だけ両stageをenqueueする。
        apply_document_first_definition(
            target_names: [:default, :new_version],
            all_sync_stage_names: {
                default:     ["default"],
                new_version: ["for_version_up", "default"],
            },
            enqueue_sync_stage_names: {
                default:     ["default"],
                new_version: ["for_version_up", "default"],
            },
            after_commit_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
        )

        first.update!(title: "largereindexdualstagetoken")

        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        refresh_index_target(new_version_index_target)

        dual_stage_search = search_document_first(
            "largereindexdualstagetoken",
            index_target: new_version_index_target,
        )
        expect(dual_stage_search.records.map(&:id)).to eq([first.id])

        first_for_version_up_request = sync_request_for(
            first,
            :new_version,
            "for_version_up",
        )
        expect(first_for_version_up_request).not_to eq(nil)
        first_for_version_up_sequence = first_for_version_up_request.request_sequence

        # 10-4後半: for_version_upの新規enqueueを止め、defaultだけを通常同期する。
        apply_document_first_definition(
            target_names: [:default, :new_version],
            all_sync_stage_names: {
                default:     ["default"],
                new_version: ["for_version_up", "default"],
            },
            enqueue_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
            after_commit_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
        )

        first.update!(title: "largereindexenqueueofftoken")

        unchanged_for_version_up_request = sync_request_for(
            first,
            :new_version,
            "for_version_up",
        )
        expect(unchanged_for_version_up_request.request_sequence).to eq(
            first_for_version_up_sequence,
        )

        # 10-5: 蓄積したfor_version_upだけをrakeで回収し、bulk中の古いdataを最新状態へ補正する。
        load_run_sync_requests_task

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke(
                "for_version_up",
            )
        end.to output(
            /通常 2 件 強制 0 件/,
        ).to_stdout

        remaining_for_version_up = AreSearch::SyncRequest.where(
            ar_model_class_name: "DocumentFirst",
            index_alias_name:    document_first_index_alias_name(:new_version),
            sync_stage_name:     "for_version_up",
        )
        expect(remaining_for_version_up.count).to eq(0)

        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        refresh_index_target(new_version_index_target)

        recovered_new_version = search_document_first(
            "largereindexduringbulktoken",
            index_target: new_version_index_target,
        )
        expect(recovered_new_version.records.map(&:id)).to eq([second.id])

        stale_new_version = search_document_first(
            "largereindexoldtoken",
            index_target: new_version_index_target,
        )
        expect(stale_new_version.records).to eq([])

        # 差分回収後はnew_versionからfor_version_upを外し、通常stageだけにする。
        apply_document_first_definition(
            target_names: [:default, :new_version],
            all_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
            enqueue_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
            after_commit_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
        )

        # 10-6: 検索入口をnew_versionへ切り替えた後も旧defaultを並行同期する。
        second.update!(title: "largereindexswitchedtoken")

        default_index_target = DocumentFirst.are_search_index_target(:default)
        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        refresh_index_target(default_index_target)
        refresh_index_target(new_version_index_target)

        old_entry_search = search_document_first(
            "largereindexswitchedtoken",
            index_target: default_index_target,
        )
        new_entry_search = search_document_first(
            "largereindexswitchedtoken",
            index_target: new_version_index_target,
        )

        expect(old_entry_search.records.map(&:id)).to eq([second.id])
        expect(new_entry_search.records.map(&:id)).to eq([second.id])

        # 10-7: 旧defaultへの新規要求を止め、new_versionだけを通常同期する。
        apply_document_first_definition(
            target_names: [:default, :new_version],
            all_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
            enqueue_sync_stage_names: {
                new_version: ["default"],
            },
            after_commit_sync_stage_names: {
                new_version: ["default"],
            },
        )

        second.update!(title: "largereindexnewonlytoken")

        default_index_target = DocumentFirst.are_search_index_target(:default)
        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        refresh_index_target(default_index_target)
        refresh_index_target(new_version_index_target)

        stopped_old_target = search_document_first(
            "largereindexnewonlytoken",
            index_target: default_index_target,
        )
        active_new_target = search_document_first(
            "largereindexnewonlytoken",
            index_target: new_version_index_target,
        )

        expect(stopped_old_target.records).to eq([])
        expect(active_new_target.records.map(&:id)).to eq([second.id])

        default_sync_request = sync_request_for(
            second,
            :default,
            "default",
        )
        expect(default_sync_request).to eq(nil)

        apply_document_first_definition(
            target_names: [:new_version],
            all_sync_stage_names: {
                new_version: ["default"],
            },
            enqueue_sync_stage_names: {
                new_version: ["default"],
            },
            after_commit_sync_stage_names: {
                new_version: ["default"],
            },
        )

        new_version_index_target = DocumentFirst.are_search_index_target(:new_version)
        final_search = search_document_first(
            "largereindexnewonlytoken",
            index_target: new_version_index_target,
        )
        expect(final_search.records.map(&:id)).to eq([second.id])

        # 10-8: 旧defaultの物理indexを削除してもnew_versionの検索を継続できる。
        delete_document_first_target_index(:default)

        expect(
            AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: document_first_index_alias_name(:default),
            ),
        ).to eq(false)

        refresh_index_target(new_version_index_target)
        after_old_index_delete = search_document_first(
            "largereindexnewonlytoken",
            index_target: new_version_index_target,
        )
        expect(after_old_index_delete.records.map(&:id)).to eq([second.id])
    end
end
