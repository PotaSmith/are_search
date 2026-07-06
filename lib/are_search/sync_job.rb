# frozen_string_literal: true

module AreSearch
    class SyncJob < ActiveJob::Base
        queue_as :are_search

        # 一時的失敗（ESサーバ起因の 5xx・タイムアウト系、および接続・通信系）のみ
        # リトライする。ServerError は HTTP 5xx 等のサーバエラーを、Faraday::Error は
        # 接続失敗・通信タイムアウト等をそれぞれまとめて捕捉する。
        # データ起因の永続的失敗（are_search_es_data の不整合等）はここにマッチせず、
        # 1回の失敗で are_search_sync_requests に記録され、rake タスク
        # （run_sync_requests）のフォールバックに委ねる。
        # attempts: 3 は初回実行を含む総試行回数（= リトライ2回）。
        retry_on(
            Elastic::Transport::Transport::ServerError,
            Faraday::Error,
            wait:     :polynomially_longer,
            attempts: 3,
        )

        def perform(database_name, ar_model_class_name, target_name, ar_instance_key, es_index_name, processing_token)
            # この constantize の失敗は通常ありえない。
            # job が残っているのに AreSearch::Searchable の include を辞めたか
            # job が変なところで動いているということだから、例外でいい。
            model = ar_model_class_name.constantize

            return if model.connection_db_config.database != database_name

            AreSearch::RecordSync.sync(ar_model_class_name, target_name, ar_instance_key, es_index_name, processing_token, reraise: true)
        end
    end
end
