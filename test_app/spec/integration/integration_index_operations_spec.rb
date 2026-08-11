# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch index guard integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_lock_dir = AreSearch.lock_dir

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        rebuild_empty_document_first_index

        Dir.mktmpdir("are_search_index_guard_integration") do |dir|
            AreSearch.lock_dir = dir
            example.run
        end
    ensure
        clear_are_search_integration_records
        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.lock_dir = original_lock_dir
    end

    it "別の処理がindex flockを保持中はskipし解放後はmarker付きで実行する" do
        index_alias_name = document_first_index_target.are_search_index_alias_name
        lock_file_path = AreSearch.index_lock_file_path(index_alias_name)
        FileUtils.mkdir_p(File.dirname(lock_file_path))

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

        block_called = false
        locked_result = document_first_index_target.are_search_with_index_guard(operation: "integration") do
            block_called = true
        end

        expect(block_called).to eq(false)
        expect(locked_result[:result]).to eq(:not_success)
        expect(locked_result[:stop_phase]).to eq(:lock_index)
        expect(locked_result[:message]).to match(/別の処理が実行中/)
        expect(AreSearch::IndexMarker.count).to eq(0)

        release_writer.write("1")
        release_writer.close
        Process.wait(child_pid)

        marker_seen_in_block = false
        unlocked_result = document_first_index_target.are_search_with_index_guard(operation: "integration") do
            marker_seen_in_block = document_first_index_target.are_search_index_marked?
        end

        expect(marker_seen_in_block).to eq(true)
        expect(unlocked_result[:result]).to eq(:success)
        expect(unlocked_result[:stop_phase]).to eq(nil)
        expect(unlocked_result[:done_phases]).to eq([:lock_index, :create_marker])
        expect(document_first_index_target.are_search_index_marked?).to eq(false)
        expect(AreSearch::IndexMarker.count).to eq(0)
    end
end

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
            done_phases:        [:lock_index, :create_marker],
            delete_index_names: [],
        )
        expect(
            AreSearch.client.indices.exists(index: physical_index_name),
        ).to eq(true)
        expect(AreSearch::IndexMarker.find_by(index_alias_name: index_alias_name)).to eq(nil)
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
            .to receive(:are_search_index_data)
            .and_wrap_original do |original_method, *args|
                data = original_method.call(*args)
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
            :create_marker,
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
