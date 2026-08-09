# frozen_string_literal: true

require "rails_helper"
require "rake"
require_relative "../support/integration_support"

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

    # callback chain用に差し替えるDocumentFirstの定義を退避する。
    def save_document_first_definition
        singleton_class = DocumentFirst.singleton_class
        singleton_method_names = [
            :are_search_all_sync_stage_names,
            :are_search_sync_stage_names_on_enqueue,
            :are_search_sync_stage_names_on_after_commit,
            :are_search_before_sync_check,
            :are_search_after_sync_callback,
        ]

        @document_first_direct_singleton_methods = {}

        singleton_method_names.each do |method_name|
            original_method_name = original_singleton_method_name(method_name)

            @document_first_direct_singleton_methods[method_name] =
                singleton_class.instance_methods(false).include?(method_name)

            singleton_class.send(
                :alias_method,
                original_method_name,
                method_name,
            )
        end

        DocumentFirst.send(
            :alias_method,
            :are_search_callback_chain_original_index_data,
            :are_search_index_data,
        )

        @document_first_definition_saved = true
    end

    # DocumentFirstへガイド記載の2stage callback chainを適用する。
    def apply_callback_chain_definition
        singleton_class = DocumentFirst.singleton_class

        singleton_class.send(
            :define_method,
            :are_search_all_sync_stage_names,
        ) do
            {
                default: ["default", "with_external_file"],
            }
        end

        singleton_class.send(
            :define_method,
            :are_search_sync_stage_names_on_enqueue,
        ) do
            {
                default: ["default"],
            }
        end

        singleton_class.send(
            :define_method,
            :are_search_sync_stage_names_on_after_commit,
        ) do
            {
                default: ["default"],
            }
        end

        singleton_class.send(
            :define_method,
            :are_search_before_sync_check,
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

        singleton_class.send(
            :define_method,
            :are_search_after_sync_callback,
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
            :are_search_index_data,
        ) do |index_target_name, sync_stage_name|
            case [index_target_name, sync_stage_name]
            when [:default, "default"]
                {
                    title:                     title,
                    body:                      "callbackdefaulttoken",
                    status:                    status,
                    user_id:                   user_id,
                    multi_response_both:       "first both",
                    multi_response_first_only: "first only",
                }
            when [:default, "with_external_file"]
                {
                    title:                     title,
                    body:                      "callbackexternaltoken",
                    status:                    status,
                    user_id:                   user_id,
                    multi_response_both:       "first both",
                    multi_response_first_only: "first only",
                }
            else
                {}
            end
        end

        reset_document_first_index_targets
    end

    # callback chain用に差し替えたDocumentFirstの定義を元へ戻す。
    def restore_document_first_definition
        return if @document_first_definition_saved != true

        singleton_class = DocumentFirst.singleton_class

        @document_first_direct_singleton_methods.each do |method_name, originally_direct|
            original_method_name = original_singleton_method_name(method_name)

            if originally_direct
                singleton_class.send(
                    :alias_method,
                    method_name,
                    original_method_name,
                )
            else
                if singleton_class.instance_methods(false).include?(method_name)
                    singleton_class.send(:remove_method, method_name)
                end
            end

            singleton_class.send(:remove_method, original_method_name)
        end

        DocumentFirst.send(
            :alias_method,
            :are_search_index_data,
            :are_search_callback_chain_original_index_data,
        )
        DocumentFirst.send(
            :remove_method,
            :are_search_callback_chain_original_index_data,
        )

        @document_first_definition_saved = false
    end

    # 退避用singleton method名を返す。
    def original_singleton_method_name(method_name)
        "are_search_callback_chain_original_#{method_name}".to_sym
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
