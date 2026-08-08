# frozen_string_literal: true

require "rails_helper"
require "action_mailer"
require "rake"
require_relative "../support/are_search_integration_support"

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
