# frozen_string_literal: true

require "fileutils"
require "securerandom"

require_relative "are_search/version"
require_relative "are_search/search_result"
require_relative "are_search/index_marker"
require_relative "are_search/index_target"
require_relative "are_search/sync_request"
require_relative "are_search/record_sync"
require_relative "are_search/sync_job"
require_relative "are_search/dump_body"
require_relative "are_search/search_base"
require_relative "are_search/search_utils"
require_relative "are_search/index_manager"
require_relative "are_search/reindexer"
require_relative "are_search/es_data_validator"
require_relative "are_search/searchable"
require_relative "are_search/single_search"
require_relative "are_search/multi_search"
require_relative "are_search/more_like_this"
require_relative "are_search/raw_search"
require_relative "are_search/rake_utils" if defined?(Rails::Railtie)
require_relative "are_search/railtie" if defined?(Rails::Railtie)

module AreSearch

    # CJK Bigram + Unigram アナライザ設定
    # Solrの CJKBigramFilterFactory outputUnigrams="true" と等価
    ANALYZER_SETTINGS = {
        analysis: {
            filter: {
                cjk_bigram_unigram: {
                    type: "cjk_bigram",
                    output_unigrams: true,
                },
            },
            analyzer: {
                cjk_index_analyzer: {
                    type: "custom",
                    tokenizer: "standard",
                    filter: %w[cjk_width lowercase cjk_bigram_unigram],
                },
                cjk_search_analyzer: {
                    type: "custom",
                    tokenizer: "standard",
                    filter: %w[cjk_width lowercase cjk_bigram],
                },
            },
        },
    }.freeze

    AFTER_COMMIT_MODES = [:job, :direct, :none].freeze

    class Error < StandardError; end

    class NotConfiguredError < Error; end
    class IndexOperationViolation < Error; end
    class IndexLockUnavailable < Error; end
    class IndexMarkerUnavailable < Error; end

    @analyzer_settings = ANALYZER_SETTINGS
    @client_block = nil
    @index_prefix = nil
    @sync_request_delay = 120
    @max_retry_count = 100
    @lock_dir = nil
    @logger = nil
    @after_commit_mode = :direct
    @index_operation_enabled = false

    @sync_request_process_hang_wait = 1800
    @max_force_attempt_count = 5

    @default_aggs_size = 200

    @validate_es_data  = true


    def self.analyzer_settings
        @analyzer_settings
    end

    def self.analyzer_settings=(value)
        @analyzer_settings = value
    end

    def self.sync_request_delay
        @sync_request_delay
    end

    def self.sync_request_delay=(value)
        @sync_request_delay = value
    end

    def self.max_retry_count
        @max_retry_count
    end

    def self.max_retry_count=(value)
        @max_retry_count = value
    end

    def self.logger
        @logger || Rails.logger
    end

    def self.logger=(value)
        @logger = value
    end

    def self.after_commit_mode
        @after_commit_mode
    end

    def self.after_commit_mode=(value)
        unless AFTER_COMMIT_MODES.include?(value)
            raise ArgumentError, "after_commit_modeは: #{AFTER_COMMIT_MODES.inspect} のいずれかで指定してください"
        end

        @after_commit_mode = value
    end

    def self.index_operation_enabled
        @index_operation_enabled
    end

    def self.index_operation_enabled=(value)
        @index_operation_enabled = value
    end

    def self.sync_request_process_hang_wait
        @sync_request_process_hang_wait
    end

    def self.sync_request_process_hang_wait=(value)
        @sync_request_process_hang_wait = value
    end

    def self.max_force_attempt_count
        @max_force_attempt_count
    end

    def self.max_force_attempt_count=(value)
        @max_force_attempt_count = value
    end

    def self.default_aggs_size
        @default_aggs_size
    end

    def self.default_aggs_size=(value)
        @default_aggs_size = value
    end

    def self.validate_es_data
        @validate_es_data
    end

    def self.validate_es_data=(value)
        @validate_es_data = value
    end

    # ロックファイル類のベースディレクトリ。
    # 配下に sync_locks/ と index_locks/ をgem側の規約で作る。
    # 未設定の場合は Rails.root/tmp/are_search を使う。
    # Rails.root に依存するため即値ではなく参照時に遅延評価する。
    def self.lock_dir
        @lock_dir || Rails.root.join("tmp", "are_search").to_s
    end

    def self.lock_dir=(value)
        @lock_dir = value
    end

    # run_sync_requests rake タスクの多重起動を防ぐためのロックファイルパス。
    # lock_dir/sync_locks/sync.lock
    def self.sync_lock_file_path
        File.join(lock_dir, "sync_locks", "sync.lock")
    end

    # index作成中、reindex、 clean_up、の多重起動防止の flock ファイルパス（モデル単位）。
    # lock_dir/index_locks/{es_index_name}.lock
    def self.index_lock_file_path(es_index_name)
        File.join(lock_dir, "index_locks", "#{es_index_name}.lock")
    end


    def self.setup(index_prefix:, &block)
        raise ArgumentError, "setup にはクライアント生成のブロックが必要です" unless block
        raise ArgumentError, "setup にはindex_prefixが必要です" unless index_prefix

        @index_prefix = index_prefix
        @client_block = block
    end

    def self.log_client_config(client)
        return if Rails.env.test?
        return unless AreSearch.logger.debug?

        client.transport.connections.connections.each do |connection|
            faraday_connection = connection.connection
            adapter = faraday_connection.builder.adapter

            AreSearch.logger.debug do
                "[AreSearch] elasticsearch client created " \
                    "host=#{connection.host.inspect} " \
                    "adapter=#{adapter.inspect} " \
                    "open_timeout=#{faraday_connection.options.open_timeout.inspect} " \
                    "timeout=#{faraday_connection.options.timeout.inspect} " \
                    "ssl_verify=#{faraday_connection.ssl.verify.inspect}"
            end
        end
    rescue StandardError => e
        AreSearch.logger.debug do
            "[AreSearch] elasticsearch client config inspect failed: #{e.class}: #{e.message}"
        end
    end

    def self.client
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @client_block

        cached_client = Thread.current.thread_variable_get(:are_search_es_client)
        return cached_client unless cached_client.nil?

        new_client = @client_block.call
        log_client_config(new_client)

        Thread.current.thread_variable_set(:are_search_es_client, new_client)

        new_client
    end

    def self.index_prefix
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @index_prefix

        @index_prefix
    end

    def self.multi_search(index_targets, query, **options)
        AreSearch::MultiSearch.search(index_targets, query, **options)
    end

    def self.more_like_this(index_targets, instance, index_target, **options)
        AreSearch::MoreLikeThis.search(index_targets, instance, index_target, **options)
    end

    def self.searchable_index_names
        Rails.application.eager_load!

        es_index_names = []

        ActiveRecord::Base.descendants.select { |klass| klass.include?(AreSearch::Searchable) }.each do |klass|
            klass.are_search_index_targets.each do |index_target|
                es_index_name = index_target.are_search_es_index_name
                next if es_index_names.include?(es_index_name)

                es_index_names << es_index_name
            end
        end

        es_index_names
    end

    def self.mark_index!(es_index_name)
        AreSearch::IndexMarker.create_manual!(es_index_name)
    end

    def self.unmark_index!(es_index_name)
        AreSearch::IndexMarker.delete_manual!(es_index_name)
    end
end
