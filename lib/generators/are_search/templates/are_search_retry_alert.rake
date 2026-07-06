# frozen_string_literal: true

# lib/tasks/are_search_retry_alert.rake
#
# are_search_sync_requests のうち retry_count / force_attempt_count が閾値に到達した行、
# または last_error があるまま長時間残っている行を検出し、
# 管理者へメールで通知する rake タスクのサンプル。
#
#   bundle exec rake are_search:alert_retry_exceeded
#
# 宛先・送信元は AreSearchRetryAlertTask 内の定数を環境に合わせて書き換えること。
# メール送信は利用側Railsアプリの config.action_mailer の設定を使う。

module AreSearchRetryAlertTask
    # 通知先・送信元（環境に合わせて書き換える）
    ALERT_MAIL_TO   = "admin@example.com"
    ALERT_MAIL_FROM = "noreply@example.com"

    # retry_count がこの値に到達した行を通知対象にする
    ALERT_RETRY_THRESHOLD = 100
    # force_attempt_count がこの値に到達した行を通知対象にする
    ALERT_FORCE_RETRY_THRESHOLD = 5
    # last_error があるままこの秒数以上残っている行を通知対象にする
    ALERT_STUCK_ERROR_WAIT = 7200

    # このタスク専用の Mailer。
    # 利用側の ApplicationMailer に依存しないよう ActionMailer::Base を直接継承する。
    class Mailer < ActionMailer::Base
        def retry_exceeded(retry_exceeded_sync_requests, force_retry_exceeded_sync_requests, stuck_error_sync_requests)

            total_count = retry_exceeded_sync_requests.size + force_retry_exceeded_sync_requests.size + stuck_error_sync_requests.size

            lines = []
            lines << "are_search_sync_requests に同期停止候補があります。"
            lines << ""
            lines << "合計件数: #{total_count}"
            lines << ""

            append_section(
                lines,
                "retry_count が #{ALERT_RETRY_THRESHOLD} に到達",
                retry_exceeded_sync_requests,
            )
            append_section(
                lines,
                "force_attempt_count が #{ALERT_FORCE_RETRY_THRESHOLD} に到達",
                force_retry_exceeded_sync_requests,
            )
            append_section(
                lines,
                "last_error があり #{ALERT_STUCK_ERROR_WAIT} 秒以上残留",
                stuck_error_sync_requests,
            )

            body = lines.join("\n")

            mail(
                to:      ALERT_MAIL_TO,
                from:    ALERT_MAIL_FROM,
                subject: "[AreSearch] sync_request の同期停止候補を検知しました (#{total_count}件)",
                body:    body,
            )
        end

        private

        def append_section(lines, title, sync_requests)
            return if sync_requests.empty?

            lines << "---- #{title} ----"
            lines << "件数: #{sync_requests.size}"
            lines << ""

            sync_requests.each do |sync_request|
                append_sync_request(lines, sync_request)
            end

            lines << ""
        end

        def append_sync_request(lines, sync_request)
            lines << "ar_model_class_name :  #{sync_request.ar_model_class_name}"
            lines << "ar_instance_key :      #{sync_request.ar_instance_key}"
            lines << "es_index_name :        #{sync_request.es_index_name}"

            lines << "retry_count :          #{sync_request.retry_count}"
            lines << "force_attempt_count :  #{sync_request.force_attempt_count}"
            lines << "processing_token :     #{sync_request.processing_token}"
            lines << "processing_at :        #{sync_request.processing_at}"
            lines << "force_attempted :      #{sync_request.force_attempted}"
            lines << "force_attempted_at :   #{sync_request.force_attempted_at}"
            lines << "updated_at :           #{sync_request.updated_at}"
            lines << "last_error :           #{sync_request.last_error}"

            lines << "--------------"
        end
    end
end

namespace :are_search do
    desc "are_search_sync_requests の retry / force / last_error 長期残留を検出して管理者にメール通知する"
    task alert_retry_exceeded: :environment do
        retry_exceeded_sync_requests = AreSearch::SyncRequest
            .where("retry_count >= ?", AreSearchRetryAlertTask::ALERT_RETRY_THRESHOLD)
            .order(retry_count: :desc)
            .to_a

        force_retry_exceeded_sync_requests = AreSearch::SyncRequest
            .where("force_attempt_count >= ?", AreSearchRetryAlertTask::ALERT_FORCE_RETRY_THRESHOLD)
            .order(force_attempt_count: :desc)
            .to_a

        stuck_error_border_time = Time.zone.now - AreSearchRetryAlertTask::ALERT_STUCK_ERROR_WAIT

        stuck_error_sync_requests = AreSearch::SyncRequest
            .where.not(last_error: [nil, ""])
            .where("updated_at < ?", stuck_error_border_time)
            .order(updated_at: :asc)
            .to_a

        total_count = retry_exceeded_sync_requests.size + force_retry_exceeded_sync_requests.size + stuck_error_sync_requests.size

        if total_count == 0
            puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] 同期停止候補の sync_request はありません"
        else
            AreSearchRetryAlertTask::Mailer
                .retry_exceeded(
                    retry_exceeded_sync_requests,
                    force_retry_exceeded_sync_requests,
                    stuck_error_sync_requests,
                )
                .deliver_now

            puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] 同期停止候補の sync_request #{total_count}件 を #{AreSearchRetryAlertTask::ALERT_MAIL_TO} に通知しました"
        end
    end
end
