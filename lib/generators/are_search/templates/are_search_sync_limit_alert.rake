# frozen_string_literal: true

module AreSearchSyncLimitAlertTask

    # lib/tasks/are_search_sync_limit_alert.rake
    #
    # are_search_sync_requests のうち sync_try_count / force_try_count が閾値に到達した行、
    # または last_error があるまま長時間残っている行を検出し、
    # 管理者へメールで通知する rake タスクのサンプル。
    #
    #   bundle exec rake 'are_search:sync_limit_alert[default]'
    #
    # 宛先・送信元は AreSearchSyncLimitAlertTask 内の定数を環境に合わせて書き換えること。
    # メール送信は利用側Railsアプリの config.action_mailer の設定を使う。

    # 通知先・送信元（環境に合わせて書き換える）
    ALERT_MAIL_TO   = "admin@example.com"
    ALERT_MAIL_FROM = "noreply@example.com"

    # メールの内容に記載する最大詳細データ数
    ALERT_MAX_RESULTS = 10

    # sync_try_count がこの値に到達した行を通知対象にする
    ALERT_SYNC_TRY_THRESHOLD = 100
    # force_try_count がこの値に到達した行を通知対象にする
    ALERT_FORCE_TRY_THRESHOLD = 5
    # last_error があるままこの秒数以上残っている行を通知対象にする
    ALERT_STUCK_ERROR_WAIT = 7200
    # request_sequence_at からこの秒数以上経過している行を通知対象にする
    ALERT_STUCK_REQUEST_WAIT = 86400

    # このタスク専用の Mailer。
    # 利用側の ApplicationMailer に依存しないよう ActionMailer::Base を直接継承する。
    class Mailer < ActionMailer::Base
        def sync_limit_alert(
            total_count,
            sync_try_limit_reached_requests,
            force_try_limit_reached_requests,
            stuck_error_sync_requests,
            stuck_request_sync_requests
        )

            lines = []
            lines << "are_search_sync_requests に同期停止候補があります。"
            lines << ""
            lines << "合計件数: #{total_count}"
            lines << ""

            append_section(
                lines,
                "sync_try_count が #{ALERT_SYNC_TRY_THRESHOLD} に到達",
                sync_try_limit_reached_requests,
            )
            append_section(
                lines,
                "force_try_count が #{ALERT_FORCE_TRY_THRESHOLD} に到達",
                force_try_limit_reached_requests,
            )
            append_section(
                lines,
                "last_error があり #{ALERT_STUCK_ERROR_WAIT} 秒以上残留",
                stuck_error_sync_requests,
            )

            append_section(
                lines,
                "#{ALERT_STUCK_REQUEST_WAIT} 秒以上残留",
                stuck_request_sync_requests,
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

            sync_requests.limit(ALERT_MAX_RESULTS).each do |sync_request|
                append_sync_request(lines, sync_request)
            end

            lines << ""
        end

        def append_sync_request(lines, sync_request)
            lines << "ar_model_class_name :  #{sync_request.ar_model_class_name}"
            lines << "ar_instance_key :      #{sync_request.ar_instance_key}"
            lines << "index_alias_name :     #{sync_request.index_alias_name}"
            lines << "sync_stage_name :      #{sync_request.sync_stage_name}"
            lines << "request_sequence :     #{sync_request.request_sequence}"
            lines << "request_sequence_at :  #{sync_request.request_sequence_at}"

            lines << "sync_try_count :       #{sync_request.sync_try_count}"
            lines << "last_sync_try_at :     #{sync_request.last_sync_try_at}"
            lines << "callback_try_count :   #{sync_request.callback_try_count}"
            lines << "last_callback_try_at : #{sync_request.last_callback_try_at}"
            lines << "last_completed_at :    #{sync_request.last_completed_at}"
            lines << "force_try_count :      #{sync_request.force_try_count}"
            lines << "processing_token :     #{sync_request.processing_token}"
            lines << "processing_at :        #{sync_request.processing_at}"
            lines << "force_attempted :      #{sync_request.force_attempted}"
            lines << "last_force_try_at :    #{sync_request.last_force_try_at}"
            lines << "updated_at :           #{sync_request.updated_at}"
            lines << "last_error_at :        #{sync_request.last_error_at}"

            lines << "--------------"
        end
    end
end

namespace :are_search do
    desc "are_search_sync_requests の sync_try / force_try / last_error 長期残留を検出して管理者にメール通知する"
    task :sync_limit_alert, [:sync_stage_names] => :environment do |_task, args|

        # sync_stage_names は引数で取得する
        sync_stage_names = args.to_a
        if sync_stage_names.empty?
            raise ArgumentError, "sync_stage_names を1件以上指定してください"
        end

        # このタスク内で処理対象にするSearchableモデルの一覧を作成する。
        models = AreSearch::RakeUtils::ArgCheck.load_models
        AreSearch::RakeUtils::ArgCheck.check_sync_stage_names(models, sync_stage_names)

        stuck_error_border_time = Time.zone.now - AreSearchSyncLimitAlertTask::ALERT_STUCK_ERROR_WAIT
        stuck_request_border_time = Time.zone.now - AreSearchSyncLimitAlertTask::ALERT_STUCK_REQUEST_WAIT

        total_count = AreSearch::SyncRequest
            .where(
                "sync_try_count >= ? OR " \
                "force_try_count >= ? OR " \
                "(last_error IS NOT NULL AND last_error != '' AND last_error_at <= ?) OR " \
                "request_sequence_at <= ?",
                AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD,
                AreSearchSyncLimitAlertTask::ALERT_FORCE_TRY_THRESHOLD,
                stuck_error_border_time,
                stuck_request_border_time,
            )
            .where(sync_stage_name: sync_stage_names)
            .count

        if total_count == 0
            puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] 同期停止候補の sync_request はありません"
        else
            sync_try_limit_reached_requests = AreSearch::SyncRequest
                .where("sync_try_count >= ?", AreSearchSyncLimitAlertTask::ALERT_SYNC_TRY_THRESHOLD)
                .where(sync_stage_name: sync_stage_names)
                .order(sync_try_count: :desc)

            force_try_limit_reached_requests = AreSearch::SyncRequest
                .where("force_try_count >= ?", AreSearchSyncLimitAlertTask::ALERT_FORCE_TRY_THRESHOLD)
                .where(sync_stage_name: sync_stage_names)
                .order(force_try_count: :desc)

            stuck_error_sync_requests = AreSearch::SyncRequest
                .where.not(last_error: [nil, ""])
                .where("last_error_at <= ?", stuck_error_border_time)
                .where(sync_stage_name: sync_stage_names)
                .order(last_error_at: :asc)

            stuck_request_sync_requests = AreSearch::SyncRequest
                .where("request_sequence_at <= ?", stuck_request_border_time)
                .where(sync_stage_name: sync_stage_names)
                .order(request_sequence_at: :asc)

            AreSearchSyncLimitAlertTask::Mailer
                .sync_limit_alert(
                    total_count,
                    sync_try_limit_reached_requests,
                    force_try_limit_reached_requests,
                    stuck_error_sync_requests,
                    stuck_request_sync_requests,
                )
                .deliver_now

            puts "#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')} [AreSearch] 同期停止候補の sync_request #{total_count}件 を #{AreSearchSyncLimitAlertTask::ALERT_MAIL_TO} に通知しました"
        end
    end
end
