# frozen_string_literal: true

class <%= migration_class_name %> < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
    def up
        execute <<~SQL
            CREATE SEQUENCE are_search_sync_requests_request_sequence
        SQL

        create_table :are_search_sync_requests, id: :bigserial do |t|
            t.string   :ar_model_class_name, null: false
            t.string   :index_target_name,   null: false
            t.string   :ar_instance_key,     null: false
            t.string   :es_index_name,       null: false

            t.bigint   :request_sequence,    null: false
            t.datetime :request_sequence_at, null: false

            t.string   :processing_token
            t.datetime :processing_at

            t.boolean  :force_attempted,     null: false, default: false
            t.datetime :force_attempted_at
            t.integer  :force_attempt_count, null: false, default: 0

            t.integer  :retry_count,         null: false, default: 0
            t.text     :last_error

            t.timestamps
        end

        add_index :are_search_sync_requests,
            [:es_index_name, :ar_model_class_name, :ar_instance_key],
            unique: true


        create_table :are_search_index_markers, id: :bigserial do |t|
            t.string   :es_index_name, null: false
            t.string   :operation,     null: false
            t.string   :owner_token,   null: false
            t.string   :owner_host
            t.integer  :owner_pid
            t.datetime :started_at,    null: false
            t.text     :message

            t.timestamps
        end

        add_index :are_search_index_markers,
            :es_index_name,
            unique: true
    end

    def down
        drop_table :are_search_index_markers

        drop_table :are_search_sync_requests

        execute <<~SQL
            DROP SEQUENCE are_search_sync_requests_request_sequence
        SQL
    end

end
