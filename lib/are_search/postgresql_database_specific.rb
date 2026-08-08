# frozen_string_literal: true

module AreSearch
    class PostgreSQLDatabaseSpecific < DatabaseSpecific

        # AreSearch が使用するPostgreSQL固有処理。

        REQUEST_SEQUENCE_SQL =
            "SELECT nextval('are_search_sequences_for_sync_requests_id_seq'::regclass)"

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
            index_alias_name:,
            sync_stage_name:,
            request_sequence:,
            request_sequence_at:
        )
            AreSearch::SyncRequest.upsert(
                {
                    ar_model_class_name: ar_model_class_name,
                    ar_instance_key:     ar_instance_key,
                    index_alias_name:    index_alias_name,
                    sync_stage_name:     sync_stage_name,
                    index_target_name:   index_target_name,
                    request_sequence:    request_sequence,
                    request_sequence_at: request_sequence_at,
                },
                unique_by: [:index_alias_name, :ar_model_class_name, :ar_instance_key, :sync_stage_name],
            )
        end
    end
end
