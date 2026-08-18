# frozen_string_literal: true

require "active_record"
require "active_job"
require "active_support"
require "active_support/time"
require "active_support/string_inquirer"

require "elasticsearch"
require "elastic/transport"
require "faraday"
require "progress_bar"

require "logger"
require "tmpdir"
require "fileutils"
require "pathname"
require "sqlite3"

module Rails
    def self.logger
        @logger ||= Logger.new(nil)
    end

    def self.root
        Pathname.new(Dir.tmpdir)
    end

    def self.env
        ActiveSupport::StringInquirer.new("test")
    end
end

Time.zone = "UTC"

require "are_search"

ActiveRecord::Base.establish_connection(
    adapter:  "sqlite3",
    database: ":memory:",
)

ActiveRecord::Schema.define do
    create_table :are_search_sync_requests, id: :integer, force: true do |t|
        t.string   :ar_model_class_name, null: false
        t.string   :index_target_name,   null: false
        t.string   :ar_instance_key,     null: false
        t.string   :index_alias_name,       null: false
        t.string   :sync_stage_name,          null: false

        t.bigint   :request_sequence,    null: false
        t.datetime :request_sequence_at, null: false

        t.string   :processing_token
        t.datetime :processing_at

        t.integer  :sync_try_count,   null: false, default: 0
        t.datetime :last_sync_try_at

        t.integer  :callback_try_count,  null: false, default: 0
        t.datetime :last_callback_try_at

        t.datetime :last_completed_at

        t.boolean  :force_attempted,     null: false, default: false
        t.datetime :last_force_try_at
        t.integer  :force_try_count, null: false, default: 0

        t.text     :last_error
        t.datetime :last_error_at

        t.timestamps
    end

    add_index :are_search_sync_requests,
        [:index_alias_name, :sync_stage_name, :ar_instance_key],
        unique: true

    add_index :are_search_sync_requests,
        [:index_alias_name, :sync_stage_name, :request_sequence]

    add_index :are_search_sync_requests,
        [:sync_stage_name, :request_sequence_at]

    add_index :are_search_sync_requests,
        [:sync_stage_name, :processing_at]


    create_table :are_search_sync_locks, id: :integer, force: true do |t|
        t.string   :index_alias_name, null: false
        t.string   :sync_stage_name,  null: false
        t.string   :operation,        null: false
        t.string   :owner_token,   null: false
        t.string   :owner_host
        t.integer  :owner_pid
        t.datetime :started_at,    null: false
        t.text     :message

        t.timestamps
    end

    add_index :are_search_sync_locks,
        [:index_alias_name, :sync_stage_name],
        unique: true


    create_table :are_search_sync_request_boundary_targets, id: :integer, force: true do |t|
        t.string   :index_alias_name,      null: false
        t.string   :sync_stage_name,       null: false
        t.bigint   :sequence_limit,        null: false
        t.datetime :last_sync_started_at
        t.datetime :last_sync_ended_at
        t.text     :message

        t.timestamps
    end

    add_index :are_search_sync_request_boundary_targets,
        [:index_alias_name, :sync_stage_name],
        unique: true
end

RSpec.configure do |config|
    # Enable flags like --only-failures and --next-failure
    config.example_status_persistence_file_path = ".rspec_status"

    # Disable RSpec exposing methods globally on `Module` and `main`
    config.disable_monkey_patching!

    config.expect_with :rspec do |c|
        c.syntax = :expect
    end

    config.after(:each) do
        AreSearch::SyncRequest.delete_all
        AreSearch::SyncLock.delete_all
        AreSearch::SyncRequestBoundaryTarget.delete_all
    end
end
