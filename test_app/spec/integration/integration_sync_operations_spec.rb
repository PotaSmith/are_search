# frozen_string_literal: true

require "rails_helper"
require "active_job"
require "rake"
require_relative "../support/integration_support"
require "tmpdir"
require "action_mailer"

RSpec.describe "AreSearch PostgreSQL sequence integration", type: :model do
    let(:connection) do
        ActiveRecord::Base.connection
    end

    let(:sequence_table_name) do
        "are_search_sequences_for_sync_requests"
    end

    let(:sequence_name) do
        "are_search_sequences_for_sync_requests_id_seq"
    end

    # 採番専用テーブルのidにPostgreSQL sequenceが割り当てられていることを確認する。
    it "採番専用テーブルのidにPostgreSQL sequenceが存在する" do
        serial_sequence_name = connection.select_value(<<~SQL)
            SELECT pg_get_serial_sequence(
                '#{sequence_table_name}',
                'id'
            )
        SQL

        expect(serial_sequence_name).to eq(
            "public.#{sequence_name}",
        )

        relation_kind = connection.select_value(<<~SQL)
            SELECT relkind
            FROM pg_class
            WHERE oid = '#{sequence_name}'::regclass
        SQL

        expect(relation_kind).to eq("S")
    end

    # next_request_sequenceがテーブルへ行を作らず、sequenceの次値だけを使用することを確認する。
    it "next_request_sequenceはPostgreSQL sequenceから単調増加する値を取得する" do
        before_count = connection.select_value(
            "SELECT COUNT(*) FROM #{sequence_table_name}",
        ).to_i

        first_sequence = AreSearch::PostgreSQLDatabaseSpecific.next_request_sequence
        second_sequence = AreSearch::PostgreSQLDatabaseSpecific.next_request_sequence

        after_count = connection.select_value(
            "SELECT COUNT(*) FROM #{sequence_table_name}",
        ).to_i

        expect(second_sequence).to eq(first_sequence + 1)
        expect(after_count).to eq(before_count)
    end
end

RSpec.describe "AreSearch transaction integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode

        AreSearch.after_commit_mode = :none

        clear_are_search_integration_records
        example.run
    ensure
        clear_are_search_integration_records
        AreSearch.after_commit_mode = original_after_commit_mode
    end

    # 指定IDのDocumentFirst用SyncRequestが存在するか返す。
    def sync_request_exists?(id)
        AreSearch::SyncRequest.exists?(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     id.to_s,
            sync_stage_name:     "default",
        )
    end

    it "createをrollbackするとレコードとSyncRequestを両方rollbackする" do
        document = nil

        DocumentFirst.transaction do
            document = DocumentFirst.create!(
                title:   "rollback create",
                body:    "rollback body",
                status:  "published",
                user_id: 1101,
            )

            expect(sync_request_exists?(document.id)).to eq(true)

            raise ActiveRecord::Rollback
        end

        expect(DocumentFirst.exists?(document.id)).to eq(false)
        expect(sync_request_exists?(document.id)).to eq(false)
    end

    it "updateをrollbackすると更新内容とSyncRequestを両方rollbackする" do
        document = DocumentFirst.create!(
            title:   "before rollback",
            body:    "rollback body",
            status:  "published",
            user_id: 1102,
        )
        AreSearch::SyncRequest.delete_all

        DocumentFirst.transaction do
            document.update!(title: "after rollback")

            expect(sync_request_exists?(document.id)).to eq(true)

            raise ActiveRecord::Rollback
        end

        expect(DocumentFirst.find(document.id).title).to eq("before rollback")
        expect(sync_request_exists?(document.id)).to eq(false)
    end

    it "destroyをrollbackするとレコード削除とSyncRequestを両方rollbackする" do
        document = DocumentFirst.create!(
            title:   "destroy rollback",
            body:    "rollback body",
            status:  "published",
            user_id: 1103,
        )
        AreSearch::SyncRequest.delete_all

        DocumentFirst.transaction do
            document.destroy!

            expect(sync_request_exists?(document.id)).to eq(true)

            raise ActiveRecord::Rollback
        end

        expect(DocumentFirst.exists?(document.id)).to eq(true)
        expect(sync_request_exists?(document.id)).to eq(false)
    end
end

RSpec.describe "AreSearch sync integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_queue_adapter = ActiveJob::Base.queue_adapter
        original_rake_application = Rake.application

        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records
        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        ActiveJob::Base.queue_adapter = original_queue_adapter
        Rake.application = original_rake_application
    end

    # run_sync_requests の配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    it "after_commit_mode noneで残ったSyncRequestをrakeで同期する" do
        AreSearch.after_commit_mode = :none
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "rakesynctoken",
            body:    "rake sync body",
            status:  "published",
            user_id: 201,
        )

        sync_request = AreSearch::SyncRequest.find_by!(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document.id.to_s,
            sync_stage_name:     "default",
        )
        expect(sync_request.processing_token).to eq(nil)

        refresh_document_first_index
        before_result = search_document_first("rakesynctoken")
        expect(before_result.records).to eq([])

        load_run_sync_requests_task
        Rake::Task["are_search:run_sync_requests"].invoke("default")

        expect(
            AreSearch::SyncRequest.find_by(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(nil)

        refresh_document_first_index
        after_result = search_document_first("rakesynctoken")

        expect(after_result.records.map(&:id)).to eq([document.id])
    end

    it "after_commit_mode jobでenqueueしたSyncJobを実行すると同期する" do
        AreSearch.after_commit_mode = :job
        ActiveJob::Base.queue_adapter = :test
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "jobsynctoken",
            body:    "job sync body",
            status:  "published",
            user_id: 202,
        )

        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(true)

        queued_job = ActiveJob::Base.queue_adapter.enqueued_jobs.find do |job|
            job[:job] == AreSearch::SyncJob
        end

        expect(queued_job).not_to eq(nil)

        AreSearch::SyncJob.perform_now(*queued_job[:args])

        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(false)

        refresh_document_first_index
        result = search_document_first("jobsynctoken")

        expect(result.records.map(&:id)).to eq([document.id])
    end

    it "updateするとdirect同期でElasticsearchの内容を更新する" do
        AreSearch.after_commit_mode = :direct

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "updatesyncbeforetoken",
            body:    "update sync body",
            status:  "published",
            user_id: 204,
        )

        refresh_document_first_index
        before_result = search_document_first("updatesyncbeforetoken")
        expect(before_result.records.map(&:id)).to eq([document.id])

        document.update!(title: "updatesyncaftertoken")

        refresh_document_first_index
        old_result = search_document_first("updatesyncbeforetoken")
        new_result = search_document_first("updatesyncaftertoken")

        expect(old_result.records).to eq([])
        expect(new_result.records.map(&:id)).to eq([document.id])
        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(false)
    end

    it "destroyするとdirect同期でElasticsearchから削除する" do
        AreSearch.after_commit_mode = :direct

        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "deletesynctoken",
            body:    "delete sync body",
            status:  "published",
            user_id: 203,
        )

        refresh_document_first_index
        before_result = search_document_first("deletesynctoken")
        expect(before_result.records.map(&:id)).to eq([document.id])

        document.destroy!

        refresh_document_first_index
        after_result = search_document_first("deletesynctoken")

        expect(after_result.records).to eq([])
        expect(
            AreSearch::SyncRequest.exists?(
                ar_model_class_name: "DocumentFirst",
                ar_instance_key:     document.id.to_s,
                sync_stage_name:     "default",
            ),
        ).to eq(false)
    end
end

RSpec.describe "AreSearch force sync integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_sync_request_process_hang_wait = AreSearch.sync_request_process_hang_wait
        original_max_force_try_count = AreSearch.max_force_try_count
        original_rake_application = Rake.application

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0
        AreSearch.sync_request_process_hang_wait = 0
        AreSearch.max_force_try_count = 5

        clear_are_search_integration_records

        example.run
    ensure
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        AreSearch.sync_request_process_hang_wait = original_sync_request_process_hang_wait
        AreSearch.max_force_try_count = original_max_force_try_count
        Rake.application = original_rake_application
    end

    # run_sync_requests の配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    it "別tokenのまま停止したSyncRequestをrakeのforce同期でElasticsearchへ反映する" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "forcesynctoken",
            body:    "force sync body",
            status:  "published",
            user_id: 801,
        )

        sync_request = AreSearch::SyncRequest.find_by!(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document.id.to_s,
            sync_stage_name:     "default",
        )
        sync_request.update_columns(
            processing_token: "stopped-worker-token",
            processing_at:    1.hour.ago,
        )

        refresh_document_first_index
        before_result = search_document_first("forcesynctoken")
        expect(before_result.records).to eq([])

        load_run_sync_requests_task

        expect do
            Rake::Task["are_search:run_sync_requests"].invoke("default")
        end.to output(
            /通常 0 件 強制 1 件/,
        ).to_stdout

        reloaded = AreSearch::SyncRequest.find(sync_request.id)

        expect(reloaded.force_attempted).to eq(true)
        expect(reloaded.force_try_count).to eq(1)
        expect(reloaded.last_force_try_at).not_to eq(nil)
        expect(reloaded.processing_token).to eq("stopped-worker-token")

        refresh_document_first_index
        after_result = search_document_first("forcesynctoken")

        expect(after_result.records.map(&:id)).to eq([document.id])
    end
end

RSpec.describe "AreSearch callback chain integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_rake_application = Rake.application

        save_document_first_definition
        apply_callback_chain_definition

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        clear_are_search_integration_records

        example.run
    ensure
        restore_document_first_definition
        reset_document_first_index_targets

        if @document_first_definition_saved
            clear_are_search_integration_records
            rebuild_empty_document_first_index
            reset_document_first_index_targets
        end

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        Rake.application = original_rake_application
    end

    # callback chain用に差し替える設定を退避する。
    def save_document_first_definition
        @original_searchable_class_setting = AreSearch.searchable_class_setting
        @document_first_definition_saved = true
    end

    # DocumentFirstへガイド記載の2stage callback chainを適用する。
    def apply_callback_chain_definition
        setting = @original_searchable_class_setting.deep_dup
        target_setting = setting.fetch("DocumentFirst").fetch(:default).deep_dup
        target_setting[:stages] = {
            "default" => {
                data_method: :callback_chain_default_search_data,
                enqueue: true,
                after_commit: true,
            },
            "with_external_file" => {
                data_method: :callback_chain_external_search_data,
                enqueue: false,
                after_commit: false,
            },
        }
        setting["DocumentFirst"] = {
            default: target_setting,
            _callbacks: {
                before_sync_check: :callback_chain_before_sync_check,
                after_sync_callback: :callback_chain_after_sync_callback,
            },
        }

        DocumentFirst.singleton_class.send(
            :define_method,
            :callback_chain_before_sync_check,
        ) do |ar_instance_key, index_target, sync_request|
            if sync_request.sync_stage_name == "with_external_file"
                return are_search_sync_request_exists?(
                    ar_instance_key,
                    index_target,
                    "default",
                ) == false
            end

            true
        end

        DocumentFirst.singleton_class.send(
            :define_method,
            :callback_chain_after_sync_callback,
        ) do |record, index_target, sync_request|
            return if record.nil?
            return if sync_request.sync_stage_name != "default"

            record.are_search_upsert_sync_request(
                index_target,
                "with_external_file",
            )
        end

        DocumentFirst.send(
            :define_method,
            :callback_chain_default_search_data,
        ) do
            {
                title:                     title,
                body:                      "callbackdefaulttoken",
                status:                    status,
                user_id:                   user_id,
                multi_response_both:       "first both",
                multi_response_first_only: "first only",
            }
        end

        DocumentFirst.send(
            :define_method,
            :callback_chain_external_search_data,
        ) do
            {
                title:                     title,
                body:                      "callbackexternaltoken",
                status:                    status,
                user_id:                   user_id,
                multi_response_both:       "first both",
                multi_response_first_only: "first only",
            }
        end

        AreSearch.searchable_class_setting = setting
        reset_document_first_index_targets
    end

    # callback chain用に差し替えた設定とメソッドを元へ戻す。
    def restore_document_first_definition
        return if @document_first_definition_saved != true

        AreSearch.searchable_class_setting = @original_searchable_class_setting

        singleton_class = DocumentFirst.singleton_class
        [
            :callback_chain_before_sync_check,
            :callback_chain_after_sync_callback,
        ].each do |method_name|
            if singleton_class.instance_methods(false).include?(method_name)
                singleton_class.send(:remove_method, method_name)
            end
        end

        [
            :callback_chain_default_search_data,
            :callback_chain_external_search_data,
        ].each do |method_name|
            if DocumentFirst.instance_methods(false).include?(method_name)
                DocumentFirst.send(:remove_method, method_name)
            end
        end

        @document_first_definition_saved = false
    end

    # DocumentFirstとSTI子クラスのIndexTargetキャッシュを現在の定義へ揃える。
    def reset_document_first_index_targets
        DocumentFirst.are_search_reset_index_targets!

        DocumentFirst.descendants.each do |model_class|
            model_class.are_search_reset_index_targets!
        end
    end

    # 指定stageのDocumentFirst用SyncRequestを返す。
    def sync_request_for(document, sync_stage_name)
        AreSearch::SyncRequest.find_by(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document.id.to_s,
            index_alias_name:    document_first_index_target.are_search_index_alias_name,
            sync_stage_name:     sync_stage_name,
        )
    end

    # run_sync_requestsの配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    # 指定stageだけをrun_sync_requestsで回収する。
    def run_sync_stage(sync_stage_name)
        task = Rake::Task["are_search:run_sync_requests"]
        task.reenable
        task.invoke(sync_stage_name)
    end

    it "前stageを待機しcallbackで作成した後stageへ同じElasticsearchドキュメントを引き継ぐ" do
        reindex_result = rebuild_empty_document_first_index
        expect(reindex_result[:result]).to eq(:success)

        document = DocumentFirst.create!(
            title:   "callbackchaintoken",
            body:    "database body",
            status:  "published",
            user_id: 1301,
        )

        default_request = sync_request_for(document, "default")
        expect(default_request).not_to eq(nil)
        expect(sync_request_for(document, "with_external_file")).to eq(nil)

        # before_sync_checkの待機動作を確認するため、後stage要求を先に作る。
        document.are_search_upsert_sync_request(
            document_first_index_target,
            "with_external_file",
        )

        external_request = sync_request_for(document, "with_external_file")
        expect(external_request).not_to eq(nil)

        external_request_id = external_request.id
        external_request_sequence = external_request.request_sequence

        load_run_sync_requests_task

        # 前stageが残っているため、後stageは要求を残したまま同期しない。
        run_sync_stage("with_external_file")

        blocked_external_request = sync_request_for(
            document,
            "with_external_file",
        )

        expect(blocked_external_request.id).to eq(external_request_id)
        expect(blocked_external_request.sync_try_count).to eq(0)
        expect(blocked_external_request.callback_try_count).to eq(0)
        expect(blocked_external_request.processing_token).to eq(nil)
        expect(blocked_external_request.last_error).to eq(nil)
        expect(sync_request_for(document, "default")).not_to eq(nil)

        refresh_document_first_index

        blocked_default_result = search_document_first("callbackdefaulttoken")
        blocked_external_result = search_document_first("callbackexternaltoken")

        expect(blocked_default_result.records).to eq([])
        expect(blocked_external_result.records).to eq([])

        # defaultを同期するとESへ第一段階を書き、callbackで後stage要求をupsertする。
        run_sync_stage("default")

        expect(sync_request_for(document, "default")).to eq(nil)

        callback_external_request = sync_request_for(
            document,
            "with_external_file",
        )

        expect(callback_external_request).not_to eq(nil)
        expect(callback_external_request.id).to eq(external_request_id)
        expect(callback_external_request.request_sequence).to be > external_request_sequence

        refresh_document_first_index

        default_result = search_document_first("callbackdefaulttoken")
        external_before_result = search_document_first("callbackexternaltoken")

        expect(default_result.records.map(&:id)).to eq([document.id])
        expect(external_before_result.records).to eq([])

        # default要求が消えた後はbefore_sync_checkを通過し、後stageの完成データへ置き換える。
        run_sync_stage("with_external_file")

        expect(sync_request_for(document, "with_external_file")).to eq(nil)
        expect(AreSearch::SyncRequest.count).to eq(0)

        refresh_document_first_index

        default_after_result = search_document_first("callbackdefaulttoken")
        external_after_result = search_document_first("callbackexternaltoken")

        expect(default_after_result.records).to eq([])
        expect(external_after_result.records.map(&:id)).to eq([document.id])
    end
end

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

    it "別の処理がsync flockを保持中はRunnerをskipして解放後は実行できる" do
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

RSpec.describe "AreSearch sync limit alert integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_delivery_method = ActionMailer::Base.delivery_method
        original_perform_deliveries = ActionMailer::Base.perform_deliveries
        original_rake_application = Rake.application

        AreSearch.after_commit_mode = :none
        ActionMailer::Base.delivery_method = :test
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.deliveries.clear

        clear_are_search_integration_records

        if Object.const_defined?(:AreSearchSyncLimitAlertTask)
            Object.send(:remove_const, :AreSearchSyncLimitAlertTask)
        end

        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        load are_search_template_path("are_search_sync_limit_alert.rake")

        example.run
    ensure
        clear_are_search_integration_records
        ActionMailer::Base.deliveries.clear

        if Object.const_defined?(:AreSearchSyncLimitAlertTask)
            Object.send(:remove_const, :AreSearchSyncLimitAlertTask)
        end

        AreSearch.after_commit_mode = original_after_commit_mode
        ActionMailer::Base.delivery_method = original_delivery_method
        ActionMailer::Base.perform_deliveries = original_perform_deliveries
        Rake.application = original_rake_application
    end

    it "sync_try_countが閾値に到達したSyncRequestをメール通知する" do
        document = DocumentFirst.create!(
            title:   "alerttoken",
            body:    "alert body",
            status:  "published",
            user_id: 301,
        )

        sync_request = AreSearch::SyncRequest.find_by!(
            ar_model_class_name: "DocumentFirst",
            ar_instance_key:     document.id.to_s,
            sync_stage_name:     "default",
        )
        sync_request.update_columns(
            sync_try_count: AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD,
        )

        Rake::Task["are_search:sync_limit_alert"].invoke

        expect(ActionMailer::Base.deliveries.length).to eq(1)

        mail = ActionMailer::Base.deliveries.first

        expect(mail.to).to eq(["admin@example.com"])
        expect(mail.subject).to include("sync_request の同期停止候補")
        expect(mail.subject).to include("(1件)")

        body = mail.body.encoded

        expect(body).to include("DocumentFirst")
        expect(body).to include(document.id.to_s)
        expect(body).to include("sync_stage_name")
        expect(body).to include("default")
        expect(body).to include(
            AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD.to_s,
        )
    end

    it "通知対象が無ければメールを送信しない" do
        expect do
            Rake::Task["are_search:sync_limit_alert"].invoke
        end.to output(
            /同期停止候補の sync_request はありません/,
        ).to_stdout

        expect(ActionMailer::Base.deliveries).to eq([])
    end
end

RSpec.describe "AreSearch sync hooks integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_sync_request_delay = AreSearch.sync_request_delay
        original_rake_application = Rake.application

        save_document_first_indexable_definition

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true
        AreSearch.sync_request_delay = 0

        clear_are_search_integration_records
        rebuild_empty_document_first_index
        example.run
    ensure
        restore_document_first_indexable_definition
        clear_are_search_integration_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        AreSearch.sync_request_delay = original_sync_request_delay
        Rake.application = original_rake_application
    end

    # DocumentFirstのdefault_indexable?差し替え前状態を退避する。
    def save_document_first_indexable_definition
        @document_first_indexable_direct = DocumentFirst.instance_methods(false).include?(:default_indexable?)

        if @document_first_indexable_direct
            DocumentFirst.send(
                :alias_method,
                :are_search_sync_hooks_original_indexable,
                :default_indexable?,
            )
        end
    end

    # DocumentFirstのdefault_indexable?を元の定義へ戻す。
    def restore_document_first_indexable_definition
        if @document_first_indexable_direct
            DocumentFirst.send(
                :alias_method,
                :default_indexable?,
                :are_search_sync_hooks_original_indexable,
            )
            DocumentFirst.send(:remove_method, :are_search_sync_hooks_original_indexable)
            return
        end

        if DocumentFirst.instance_methods(false).include?(:default_indexable?)
            DocumentFirst.send(:remove_method, :default_indexable?)
        end
    end

    # statusがhiddenのレコードをindex対象外とする利用側hookを適用する。
    def apply_hidden_document_indexable_definition
        DocumentFirst.send(
            :define_method,
            :default_indexable?,
        ) do
            status != "hidden"
        end
    end

    # run_sync_requestsの配布templateを独立したRake applicationへ読み込む。
    def load_run_sync_requests_task
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        load are_search_template_path("are_search_run_sync_requests.rake")
    end

    it "indexable_methodがfalseへ変わると通常同期でElasticsearchから削除する" do
        apply_hidden_document_indexable_definition

        document = DocumentFirst.create!(
            title:   "syncindexabletoken",
            body:    "visible body",
            status:  "published",
            user_id: 1401,
        )

        refresh_document_first_index
        before_result = search_document_first("syncindexabletoken")
        expect(before_result.records.map(&:id)).to eq([document.id])

        document.update!(status: "hidden")

        refresh_document_first_index
        after_result = search_document_first("syncindexabletoken")
        expect(after_result.records).to eq([])
        expect(AreSearch::SyncRequest.count).to eq(0)
        expect(DocumentFirst.exists?(document.id)).to eq(true)
    end

    it "manual sync lock中はrake同期を残しrelease後にElasticsearchへ反映する" do
        AreSearch.after_commit_mode = :none

        document = DocumentFirst.create!(
            title:   "synclocktoken",
            body:    "manual sync lock body",
            status:  "published",
            user_id: 1402,
        )

        expect(AreSearch::SyncRequest.count).to eq(1)

        sync_lock = document_first_index_target.are_search_acquire_sync_lock!
        expect(sync_lock).not_to eq(nil)
        expect(document_first_index_target.are_search_index_target_syncable?).to eq(false)

        load_run_sync_requests_task
        Rake::Task["are_search:run_sync_requests"].invoke("default")

        refresh_document_first_index
        locked_result = search_document_first("synclocktoken")
        expect(locked_result.records).to eq([])
        expect(AreSearch::SyncRequest.count).to eq(1)

        deleted_count = document_first_index_target.are_search_release_sync_lock!
        expect(deleted_count).to eq(1)
        expect(document_first_index_target.are_search_index_target_syncable?).to eq(true)

        task = Rake::Task["are_search:run_sync_requests"]
        task.reenable
        task.invoke("default")

        refresh_document_first_index
        unlocked_result = search_document_first("synclocktoken")
        expect(unlocked_result.records.map(&:id)).to eq([document.id])
        expect(AreSearch::SyncRequest.count).to eq(0)
    end
end
