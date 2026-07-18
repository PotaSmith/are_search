# frozen_string_literal: true

module AreSearch
    # PostgreSQL sequence を使用してsync requestの世代番号を発行する。
    class PostgreSQLRequestSequenceProvider < RequestSequenceProvider
        REQUEST_SEQUENCE_SQL =
            "SELECT nextval('are_search_sync_requests_request_sequence'::regclass)"

        # PostgreSQL sequence から次の世代番号を取得する。
        def self.next_value
            ActiveRecord::Base.with_connection do |connection|
                connection.select_value(REQUEST_SEQUENCE_SQL).to_i
            end
        end
    end
end
