# frozen_string_literal: true

require "spec_helper"
require "rake"
require "action_mailer"

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
