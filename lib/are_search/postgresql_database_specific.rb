# frozen_string_literal: true

module AreSearch
    class PostgreSQLDatabaseSpecific < DatabaseSpecific

        # AreSearch が使用するPostgreSQL固有処理。

        REQUEST_SEQUENCE_SQL =
            "SELECT nextval('are_search_sync_requests_request_sequence'::regclass)"

        # PostgreSQL sequence から次の同期要求世代番号を取得する。
        def self.next_request_sequence
            ActiveRecord::Base.with_connection do |connection|
                connection.select_value(REQUEST_SEQUENCE_SQL).to_i
            end
        end

        # 同期要求をPostgreSQLへ登録または更新する。
        def self.upsert(
            ar_model_class_name:,
            index_target_name:,
            ar_instance_key:,
            es_index_name:,
            request_sequence:,
            request_sequence_at:
        )
            AreSearch::SyncRequest.upsert(
                {
                    ar_model_class_name: ar_model_class_name,
                    index_target_name:   index_target_name,
                    ar_instance_key:     ar_instance_key,
                    es_index_name:       es_index_name,
                    request_sequence:    request_sequence,
                    request_sequence_at: request_sequence_at,
                    retry_count:         0,
                    last_error:          nil,
                },
                unique_by: [:es_index_name, :ar_model_class_name, :ar_instance_key],
            )
        end
    end
end
