# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch PostgreSQL sequence integration", type: :model do
    let(:connection) do
        ActiveRecord::Base.connection
    end

    let(:sequence_table_name) do
        "are_search_sequences_for_sync_requests"
    end

    let(:sequence_name) do
        "are_search_sequences_for_sync_requests_id_seq"
    end

    # 採番専用テーブルのidにPostgreSQL sequenceが割り当てられていることを確認する。
    it "採番専用テーブルのidにPostgreSQL sequenceが存在する" do
        serial_sequence_name = connection.select_value(<<~SQL)
            SELECT pg_get_serial_sequence(
                '#{sequence_table_name}',
                'id'
            )
        SQL

        expect(serial_sequence_name).to eq(
            "public.#{sequence_name}",
        )

        relation_kind = connection.select_value(<<~SQL)
            SELECT relkind
            FROM pg_class
            WHERE oid = '#{sequence_name}'::regclass
        SQL

        expect(relation_kind).to eq("S")
    end

    # next_request_sequenceがテーブルへ行を作らず、sequenceの次値だけを使用することを確認する。
    it "next_request_sequenceはPostgreSQL sequenceから単調増加する値を取得する" do
        before_count = connection.select_value(
            "SELECT COUNT(*) FROM #{sequence_table_name}",
        ).to_i

        first_sequence = AreSearch::PostgreSQLDatabaseSpecific.next_request_sequence
        second_sequence = AreSearch::PostgreSQLDatabaseSpecific.next_request_sequence

        after_count = connection.select_value(
            "SELECT COUNT(*) FROM #{sequence_table_name}",
        ).to_i

        expect(second_sequence).to eq(first_sequence + 1)
        expect(after_count).to eq(before_count)
    end
end
