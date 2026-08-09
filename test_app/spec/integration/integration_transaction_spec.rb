# frozen_string_literal: true

require "rails_helper"
require_relative "../support/integration_support"

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
