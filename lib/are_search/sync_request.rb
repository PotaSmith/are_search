# frozen_string_literal: true

module AreSearch
    class SyncRequest < ActiveRecord::Base
        self.table_name = "are_search_sync_requests"

        REQUEST_POSTGRESQL_SEQUENCE_SQL =
            "SELECT nextval('are_search_sync_requests_request_sequence'::regclass)"

        def self.next_request_sequence
            ActiveRecord::Base.with_connection do |connection|
                connection.select_value(REQUEST_POSTGRESQL_SEQUENCE_SQL).to_i
            end
        end

    end
end
