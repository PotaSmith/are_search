# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch create index integration", type: :model do
    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        delete_document_second_physical_indexes

        example.run
    ensure
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        delete_document_second_physical_indexes

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentSecondのaliasから生成された物理indexを削除する。
    def delete_document_second_physical_indexes
        index_target = DocumentSecond.are_search_index_target(:default)
        response = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: index_target.are_search_index_alias_name,
        )

        response.keys.each do |physical_index_name|
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end
    end

    it "DBにレコードがあっても空indexを作成してaliasを接続する" do
        document = DocumentSecond.create!(
            title:   "createindextoken",
            body:    "create index body",
            status:  "published",
            user_id: 501,
        )

        index_target = DocumentSecond.are_search_index_target(:default)

        expect(index_target.are_search_index_alias_exists?).to eq(false)

        result = index_target.are_search_create_index

        expect(result[:result]).to eq(:success)
        expect(index_target.are_search_index_alias_exists?).to eq(true)

        physical_index_names = AreSearch::IndexManager.physical_index_names_by_alias(
            index_target.are_search_index_alias_name,
        )
        expect(physical_index_names.length).to eq(1)

        count_response = AreSearch.client.count(
            index: index_target.are_search_index_alias_name,
        )

        expect(count_response["count"]).to eq(0)
        expect(DocumentSecond.exists?(document.id)).to eq(true)
    end
end

RSpec.describe "AreSearch reindex integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        delete_document_first_physical_indexes
        example.run
    ensure
        clear_are_search_integration_records
        delete_document_first_physical_indexes

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentFirstのaliasから生成された物理indexをすべて削除する。
    def delete_document_first_physical_indexes
        response = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: document_first_index_target.are_search_index_alias_name,
        )

        response.keys.each do |physical_index_name|
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end
    end

    it "aliasが無く物理indexだけ存在する場合はcheck_aliasで停止して削除しない" do
        index_alias_name = document_first_index_target.are_search_index_alias_name
        physical_index_name = "#{index_alias_name}__2026_08_11_21_55_00_000001"

        AreSearch.client.indices.create(index: physical_index_name)

        result = AreSearch::IndexManager.index_clean_up(index_alias_name)

        expect(result).to eq(
            result:             :not_success,
            message:            "alias が存在しないため clean up を実行できません",
            stop_phase:         :check_alias,
            done_phases:        [:lock_index, :acquire_index_target_sync_lock],
            delete_index_names: [],
        )
        expect(
            AreSearch.client.indices.exists(index: physical_index_name),
        ).to eq(true)
        expect(AreSearch::SyncLock.find_by(index_alias_name: index_alias_name)).to eq(nil)
    end

    it "別targetとtimestamp形式ではないindexはclean_upで削除しない" do
        rebuild_result = rebuild_empty_document_first_index
        expect(rebuild_result[:result]).to eq(:success)

        index_alias_name = document_first_index_target.are_search_index_alias_name
        current_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(index_alias_name)
        expect(current_physical_names.length).to eq(1)

        old_physical_name = "#{index_alias_name}__2026_08_11_21_55_00_000001"
        other_target_name = "#{AreSearch.index_prefix}__document_firsts__archive__2026_08_11_21_55_00_000001"
        arbitrary_suffix_name = "#{index_alias_name}__backup"

        AreSearch.client.indices.create(index: old_physical_name)
        AreSearch.client.indices.create(index: other_target_name)
        AreSearch.client.indices.create(index: arbitrary_suffix_name)

        result = AreSearch::IndexManager.index_clean_up(index_alias_name)

        expect(result[:result]).to eq(:success)
        expect(result[:delete_index_names]).to eq([old_physical_name])
        expect(
            AreSearch.client.indices.exists(index: old_physical_name),
        ).to eq(false)
        expect(
            AreSearch.client.indices.exists(index: other_target_name),
        ).to eq(true)
        expect(
            AreSearch.client.indices.exists(index: arbitrary_suffix_name),
        ).to eq(true)
        expect(
            AreSearch::IndexManager.physical_index_names_by_alias(index_alias_name),
        ).to eq(current_physical_names)
    ensure
        [other_target_name, arbitrary_suffix_name].compact.each do |index_name|
            begin
                AreSearch.client.indices.delete(index: index_name)
            rescue Elastic::Transport::Transport::Errors::NotFound
                nil
            end
        end
    end

    it "reindexを2回実行した後clean_upで旧物理indexだけを削除する" do
        first_result = rebuild_empty_document_first_index
        expect(first_result[:result]).to eq(:success)

        first_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(first_physical_names.length).to eq(1)

        DocumentFirst.create!(
            title:   "reindexlifecycletoken",
            body:    "second reindex body",
            status:  "published",
            user_id: 1001,
        )

        second_result = document_first_index_target.are_search_reindex(
            stage_position: :first,
        )
        expect(second_result[:result]).to eq(:success)

        second_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(second_physical_names.length).to eq(1)
        expect(second_physical_names).not_to eq(first_physical_names)

        all_physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: document_first_index_target.are_search_index_alias_name,
        ).keys
        expect(all_physical_names.sort).to eq(
            (first_physical_names + second_physical_names).sort,
        )

        clean_up_result = AreSearch::IndexManager.index_clean_up(
            document_first_index_target.are_search_index_alias_name,
        )

        expect(clean_up_result[:result]).to eq(:success)
        expect(clean_up_result[:delete_index_names]).to eq(first_physical_names)
        expect(
            AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: document_first_index_target.are_search_index_alias_name,
            ).keys,
        ).to eq(second_physical_names)
    end

    it "実Elasticsearchのbulk部分失敗時はfailed_idsを返してaliasを切り替えない" do
        first_result = rebuild_empty_document_first_index
        expect(first_result[:result]).to eq(:success)

        old_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(old_physical_names.length).to eq(1)

        success_document = DocumentFirst.create!(
            title:   "reindexfailuretoken success",
            body:    "valid document",
            status:  "published",
            user_id: 1002,
        )
        failed_document = DocumentFirst.create!(
            title:   "reindexfailuretoken failed",
            body:    "invalid long document",
            status:  "published",
            user_id: 1003,
        )

        allow_any_instance_of(DocumentFirst)
            .to receive(:default_search_data)
            .and_wrap_original do |original_method|
                data = original_method.call
                record = original_method.receiver

                if record.id == failed_document.id
                    data[:user_id] = 10 ** 30
                end

                data
            end

        result = document_first_index_target.are_search_reindex(
            stage_position: :first,
        )

        expect(result[:result]).to eq(:not_success)
        expect(result[:failed_ids]).to eq([failed_document.id])
        expect(result[:stop_phase]).to eq(:index_to_new_index)
        expect(result[:done_phases]).to include(
            :lock_index,
            :acquire_index_target_sync_lock,
            :create_new_index,
        )
        expect(result[:done_phases]).not_to include(:switch_alias)

        current_physical_names = AreSearch::IndexManager.physical_index_names_by_alias(
            document_first_index_target.are_search_index_alias_name,
        )
        expect(current_physical_names).to eq(old_physical_names)

        all_physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: document_first_index_target.are_search_index_alias_name,
        ).keys
        expect(all_physical_names.length).to eq(2)

        refresh_document_first_index
        search_result = search_document_first("reindexfailuretoken")
        expect(search_result.records).to eq([])

        expect(DocumentFirst.exists?(success_document.id)).to eq(true)
        expect(DocumentFirst.exists?(failed_document.id)).to eq(true)
    end
end

RSpec.describe "AreSearch large reindex migration integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_rake_application = Rake.application

        @original_searchable_class_setting = AreSearch.searchable_class_setting
        @base_target_setting = @original_searchable_class_setting.fetch("DocumentFirst").fetch(:default).deep_dup

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        clear_are_search_integration_records
        delete_document_first_target_index(:new_version)

        example.run
    ensure
        if @original_searchable_class_setting
            AreSearch.searchable_class_setting = @original_searchable_class_setting
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

    # 指定targetとstage構成を設定へ適用し、IndexTargetのキャッシュを作り直す。
    def apply_document_first_definition(
        target_names:,
        all_sync_stage_names:,
        enqueue_sync_stage_names:,
        after_commit_sync_stage_names:
    )
        setting = @original_searchable_class_setting.deep_dup
        document_first_setting = {}

        target_names.each do |index_target_name|
            target_setting = @base_target_setting.deep_dup
            stage_settings = {}

            all_sync_stage_names.fetch(index_target_name).each do |sync_stage_name|
                stage_settings[sync_stage_name] = {
                    data_method: :default_search_data,
                    enqueue: enqueue_sync_stage_names.fetch(index_target_name, []).include?(sync_stage_name),
                    after_commit: after_commit_sync_stage_names.fetch(index_target_name, []).include?(sync_stage_name),
                }
            end

            target_setting[:stages] = stage_settings
            document_first_setting[index_target_name] = target_setting
        end

        setting["DocumentFirst"] = document_first_setting
        AreSearch.searchable_class_setting = setting
        reset_document_first_index_targets
    end

    # DocumentFirstとSTI子クラスのIndexTargetキャッシュを現在の定義へ揃える。
    def reset_document_first_index_targets
        DocumentFirst.are_search_reset_index_targets!

        DocumentFirst.descendants.each do |model_class|
            model_class.are_search_reset_index_targets!
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

    # Boundary操作の配布templateをDocumentFirst用設定で独立したRake applicationへ読み込む。
    def load_sync_request_boundary_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        if Object.const_defined?(:AreSearchSyncRequestBoundaryChangeYourTaskNameTask, false)
            Object.send(:remove_const, :AreSearchSyncRequestBoundaryChangeYourTaskNameTask)
        end

        load are_search_template_path("are_search_sync_request_boundary.rake")

        stub_const(
            "AreSearchSyncRequestBoundaryChangeYourTaskNameTask::INDEX_TARGET_MODEL_CLASS_NAME",
            "DocumentFirst",
        )
        stub_const(
            "AreSearchSyncRequestBoundaryChangeYourTaskNameTask::INDEX_TARGET_NAME",
            "default",
        )
        stub_const(
            "AreSearchSyncRequestBoundaryChangeYourTaskNameTask::SYNC_STAGE_NAME",
            "huge_data_for_reindex",
        )
    end

    it "巨大データ切り替え手順でsync lock中の更新を差分回収して新IndexTargetへ移行する" do
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

        # 10-1: new_versionにも通常のdefault stageを追加し、旧defaultと並行してSyncRequestを作る。
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

        first.update!(title: "largereindexprebulktoken")

        pre_bulk_request = sync_request_for(
            first,
            :new_version,
            "default",
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

        # 10-3: new_version/defaultをlockし、lock取得前からprocessing中の要求が残っていないことを確認する。
        sync_stage_name = "default"
        sync_lock = new_version_index_target.are_search_acquire_sync_stage_lock!(sync_stage_name)

        expect(sync_lock).not_to eq(nil)
        expect(new_version_index_target.are_search_sync_stage_locked?(sync_stage_name)).to eq(true)
        expect(
            new_version_index_target.are_search_processing_sync_stage_sync_request_exists?(sync_stage_name),
        ).to eq(false)

        # 10-4: bulk用dataを作った直後にDB更新を割り込ませ、lock中のSyncRequestを残して古いdataを送る。
        updated_during_bulk = false

        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data_for_index!)
            .and_wrap_original do |original_method, index_target, current_sync_stage_name|
                record = original_method.receiver
                data = original_method.call(index_target, current_sync_stage_name)

                if updated_during_bulk == false &&
                        record.id == second.id &&
                        index_target.index_target_name == :new_version &&
                        current_sync_stage_name == "default"
                    updated_during_bulk = true

                    DocumentFirst.find(second.id).update!(
                        title: "largereindexduringbulktoken",
                    )
                end

                data
            end

        Dir.mktmpdir("are_search_large_reindex_integration") do |result_dir|
            new_version_index_target.are_search_bulk_index(
                sync_stage_name,
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )
        end

        expect(updated_during_bulk).to eq(true)
        expect(new_version_index_target.are_search_sync_stage_locked?(sync_stage_name)).to eq(true)

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
            "default",
        )
        expect(during_bulk_request).not_to eq(nil)

        # 10-5: lockを解除し、new_version/defaultに残った通常SyncRequestをrakeで回収する。
        new_version_index_target.are_search_release_sync_stage_lock!(sync_stage_name)
        expect(new_version_index_target.are_search_sync_stage_locked?(sync_stage_name)).to eq(false)

        load_run_sync_requests_task

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke(
                "default",
            )
        end.to output(
            /通常同期 2 件 強制同期 0 件/,
        ).to_stdout

        remaining_new_version_requests = AreSearch::SyncRequest.where(
            ar_model_class_name: "DocumentFirst",
            index_alias_name:    document_first_index_alias_name(:new_version),
            sync_stage_name:     "default",
        )
        expect(remaining_new_version_requests.count).to eq(0)

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

        # 10-7: 旧defaultのstage定義は残したままenqueueとafter_commitを止める。
        apply_document_first_definition(
            target_names: [:default, :new_version],
            all_sync_stage_names: {
                default:     ["default"],
                new_version: ["default"],
            },
            enqueue_sync_stage_names: {
                default:     [],
                new_version: ["default"],
            },
            after_commit_sync_stage_names: {
                default:     [],
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

    it "通常同期を継続したままbulk中の更新をBoundaryで差分回収する" do
        apply_document_first_definition(
            target_names: [:default],
            all_sync_stage_names: {
                default: [
                    "default",
                    "huge_data",
                    "huge_data_for_reindex",
                ],
            },
            enqueue_sync_stage_names: {
                default: [
                    "default",
                    "huge_data",
                    "huge_data_for_reindex",
                ],
            },
            after_commit_sync_stage_names: {
                default: ["default"],
            },
        )

        initial_reindex = rebuild_empty_document_first_index
        expect(initial_reindex[:result]).to eq(:success)

        AreSearch::SyncRequestBoundaryTarget.delete_all

        first = DocumentFirst.create!(
            title:   "boundarybulk first",
            body:    "first body",
            status:  "published",
            user_id: 911,
        )
        second = DocumentFirst.create!(
            title:   "boundarybulkoldtoken",
            body:    "second body",
            status:  "published",
            user_id: 912,
        )

        # 11-1: 通常rakeではdefaultとhuge_dataだけを処理し、差分回収stageは蓄積する。
        load_run_sync_requests_task

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke(
                "default",
                "huge_data",
            )
        end.to output(
            /通常同期 2 件 強制同期 0 件/,
        ).to_stdout

        reindex_stage_scope = AreSearch::SyncRequest.where(
            index_alias_name: document_first_index_alias_name(:default),
            sync_stage_name:  "huge_data_for_reindex",
        )
        expect(reindex_stage_scope.count).to eq(2)

        # 11-2, 11-3: Boundary taskを読み込み、bulk開始前に差分回収stageだけをclearする。
        load_sync_request_boundary_task

        allow($stdin)
            .to receive(:gets)
            .and_return("y\n")

        expect do
            Rake::Task["are_search:my_boundary_task_delete_sync_stage_all_sync_requests"].invoke
        end.to output(
            /sync_request を削除しました。2件/,
        ).to_stdout
        expect(reindex_stage_scope.count).to eq(0)

        default_index_target = DocumentFirst.are_search_index_target(:default)
        updated_during_bulk = false

        # 11-4: bulk用data生成直後に更新を割り込ませ、古いdataをElasticsearchへ送る。
        allow_any_instance_of(DocumentFirst)
            .to receive(:are_search_index_data_for_index!)
            .and_wrap_original do |original_method, index_target, sync_stage_name|
                record = original_method.receiver
                data = original_method.call(index_target, sync_stage_name)

                if updated_during_bulk == false &&
                        record.id == second.id &&
                        index_target.index_target_name == :default &&
                        sync_stage_name == "huge_data_for_reindex"
                    updated_during_bulk = true

                    DocumentFirst.find(second.id).update!(
                        title: "boundarybulkduringtoken",
                    )
                end

                data
            end

        Dir.mktmpdir("are_search_boundary_bulk_integration") do |result_dir|
            default_index_target.are_search_bulk_index(
                "huge_data_for_reindex",
                result_dir:      result_dir,
                max_bulk_bytes:  1024 * 1024,
                max_bulk_count:  10,
                max_fail_count:  10,
            )
        end

        expect(updated_during_bulk).to eq(true)
        refresh_index_target(default_index_target)

        stale_result = search_document_first(
            "boundarybulkoldtoken",
            index_target: default_index_target,
        )
        updated_result = search_document_first(
            "boundarybulkduringtoken",
            index_target: default_index_target,
        )
        expect(stale_result.records.map(&:id)).to eq([second.id])
        expect(updated_result.records).to eq([])

        during_bulk_request = sync_request_for(
            second,
            :default,
            "huge_data_for_reindex",
        )
        expect(during_bulk_request).not_to eq(nil)

        # 11-5: bulk完了時点を境界として保存する。
        expect do
            Rake::Task["are_search:my_boundary_task_set_sync_request_boundary"].invoke
        end.to output(
            /BoundaryTargetをセットしました。limit=/,
        ).to_stdout

        boundary_target = AreSearch::SyncRequestBoundaryTarget.find_by!(
            index_alias_name: document_first_index_alias_name(:default),
            sync_stage_name:  "huge_data_for_reindex",
        )
        expect(during_bulk_request.reload.request_sequence).to be <= boundary_target.sequence_limit

        # set_sync_request_boundary後の更新は今回の差分回収対象に含めない。
        first.update!(title: "boundarybulkaftertoken")

        after_boundary_request = sync_request_for(
            first,
            :default,
            "huge_data_for_reindex",
        )
        expect(after_boundary_request).not_to eq(nil)
        expect(after_boundary_request.request_sequence).to be > boundary_target.sequence_limit

        # 11-6: 今回の境界までを同期し、bulk中の古いdataを最新状態へ戻す。
        allow($stdin)
            .to receive(:gets)
            .and_return("y\n")

        boundary_run_task = Rake::Task["are_search:my_boundary_task_run_sync_request_before_boundary"]

        expect do
            boundary_run_task.invoke
        end.to output(
            /Boundary同期対象 実行前 1件.*Boundary同期対象 実行後 0件/m,
        ).to_stdout

        expect(
            sync_request_for(second, :default, "huge_data_for_reindex"),
        ).to eq(nil)
        expect(
            sync_request_for(first, :default, "huge_data_for_reindex"),
        ).not_to eq(nil)

        huge_data_scope = AreSearch::SyncRequest.where(
            index_alias_name: document_first_index_alias_name(:default),
            sync_stage_name:  "huge_data",
        )
        expect(huge_data_scope.count).to eq(2)

        refresh_index_target(default_index_target)
        recovered_result = search_document_first(
            "boundarybulkduringtoken",
            index_target: default_index_target,
        )
        expect(recovered_result.records.map(&:id)).to eq([second.id])

        # 境界対象が0件なら再実行しても同期を開始しない。
        boundary_run_task.reenable

        expect do
            boundary_run_task.invoke
        end.to output(
            /Boundary同期対象 実行前 0件/,
        ).to_stdout

        expect do
            Rake::Task["are_search:my_boundary_task_clear_sync_request_boundary"].invoke
        end.to output(/BoundaryTargetをクリアしました。/).to_stdout

        expect(
            AreSearch::SyncRequestBoundaryTarget.exists?(boundary_target.id),
        ).to eq(false)
    ensure
        AreSearch::SyncRequestBoundaryTarget.delete_all
    end
end

RSpec.describe "AreSearch rake index operations integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_rake_application = Rake.application
        original_stdin = $stdin

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true

        clear_are_search_integration_records([DocumentFirst, DocumentSecond])
        prepare_all_indexes
        example.run
    ensure
        $stdin = original_stdin
        Rake.application = original_rake_application
        clear_are_search_integration_records([DocumentFirst, DocumentSecond])

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
    end

    # Rake対象になる全root modelのindexを作成し、古い物理indexを残さない。
    def prepare_all_indexes
        [DocumentFirst, DocumentSecond].each do |model_class|
            index_target = model_class.are_search_index_target(:default)
            result = index_target.are_search_reindex(stage_position: :first)
            expect(result[:result]).to eq(:success)

            clean_result = index_target.are_search_clean_up
            expect(clean_result[:result]).to eq(:success)
        end

        AreSearch::SyncRequest.delete_all
    end

    # gem本体のindex運用Rake taskを独立したRake applicationへ読み込む。
    def load_index_rake_tasks
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        gem_root = Gem.loaded_specs.fetch("are_search").full_gem_path
        load File.join(gem_root, "lib", "tasks", "are_search.rake")
    end

    # 現在aliasが指す物理index名を返す。
    def current_physical_index_name(index_target)
        names = AreSearch::IndexManager.physical_index_names_by_alias(
            index_target.are_search_index_alias_name,
        )
        expect(names.length).to eq(1)

        names.first
    end

    it "reindex_all_for_es_version_upで全root modelを実Elasticsearchへreindexする" do
        first = DocumentFirst.create!(
            title:   "rakeversionuptoken first",
            body:    "first model",
            status:  "published",
            user_id: 1501,
        )
        second = DocumentSecond.create!(
            title:   "rakeversionuptoken second",
            body:    "second model",
            status:  "published",
            user_id: 1502,
        )
        AreSearch::SyncRequest.delete_all

        first_target = DocumentFirst.are_search_index_target(:default)
        second_target = DocumentSecond.are_search_index_target(:default)
        before_names = [
            current_physical_index_name(first_target),
            current_physical_index_name(second_target),
        ]

        load_index_rake_tasks
        $stdin = StringIO.new("y\n")
        Rake::Task["are_search:reindex_all_for_es_version_up"].invoke

        after_names = [
            current_physical_index_name(first_target),
            current_physical_index_name(second_target),
        ]
        expect(after_names).not_to eq(before_names)

        refresh_integration_indexes([first_target, second_target])
        result = search_integration_indexes(
            [first_target, second_target],
            "rakeversionuptoken",
        )
        expect(result.records.map(&:id).sort).to eq([first.id, second.id].sort)
    end

    it "clean_up_allで全root modelのcurrent以外の物理indexを削除する" do
        first_target = DocumentFirst.are_search_index_target(:default)
        second_target = DocumentSecond.are_search_index_target(:default)

        [first_target, second_target].each do |index_target|
            result = index_target.are_search_reindex(stage_position: :first)
            expect(result[:result]).to eq(:success)

            all_physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: index_target.are_search_index_alias_name,
            ).keys
            expect(all_physical_names.length).to be >= 2
        end

        load_index_rake_tasks
        Rake::Task["are_search:clean_up_all"].invoke

        [first_target, second_target].each do |index_target|
            current_names = AreSearch::IndexManager.physical_index_names_by_alias(
                index_target.are_search_index_alias_name,
            )
            all_physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: index_target.are_search_index_alias_name,
            ).keys

            expect(current_names.length).to eq(1)
            expect(all_physical_names).to eq(current_names)
        end
    end
end
