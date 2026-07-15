# frozen_string_literal: true

require "fileutils"
require "securerandom"

module AreSearch
    # alias の各要素と、alias と物理 index timestamp の境界に使用する。
    ES_INDEX_NAME_DELIMITER = "__"

    # Elasticsearch index 名を構成する各要素の共通形式。
    # 小文字英字で始まり、小文字英字とアンダーバーだけを使用する。
    ES_INDEX_NAME_ELEMENT_PATTERN = /\A[a-z][a-z_]*\z/.freeze

    # 空の index_prefix を index 名の先頭要素として残すための代理値。
    EMPTY_ES_INDEX_PREFIX = "are_search_no_prefix"

    # 値が Elasticsearch index 名の要素として使用できる形式かを判定する。
    def self.valid_es_index_name_element?(value)
        return false unless value.instance_of?(String)

        value.match?(ES_INDEX_NAME_ELEMENT_PATTERN)
    end
end

require_relative "are_search/version"
require_relative "are_search/index_marker"
require_relative "are_search/index_target"
require_relative "are_search/sync_request"
require_relative "are_search/record_sync"
require_relative "are_search/sync_job"
require_relative "are_search/index_manager"
require_relative "are_search/reindexer"
require_relative "are_search/es_data_validator"
require_relative "are_search/searchable"


require_relative "are_search/searcher/search_result"
require_relative "are_search/searcher/searcher_utils"
require_relative "are_search/searcher/es_search_body_policy"

require_relative "are_search/searcher/validator/search_option_definition"
require_relative "are_search/searcher/validator/search_option_validator"
require_relative "are_search/searcher/validator/search_param_validator"

require_relative "are_search/searcher/query_builder/query_builder_base"
require_relative "are_search/searcher/query_builder/simple_query_builder"
require_relative "are_search/searcher/query_builder/complex_field_query_builder"
require_relative "are_search/searcher/query_builder/more_like_this_query_builder"
require_relative "are_search/searcher/query_builder/raw_query_builder"
require_relative "are_search/searcher/query_builder_selector"

require_relative "are_search/searcher/body_builder/body_builder_base"
require_relative "are_search/searcher/body_builder/standard_body_builder"
require_relative "are_search/searcher/body_builder/raw_body_builder"
require_relative "are_search/searcher/body_builder_selector"

require_relative "are_search/searcher/searcher"


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

    RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME = :are_search_es_ar_model_class_name
    RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME = :are_search_es_ar_instance_key
    RESERVED_ES_FIELD_NAME_SETTING = { type: 'keyword' }

    RESERVED_ES_FIELD_NAMES = [
        RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME,
        RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME,
    ].freeze

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
    @batch_size = 500

    @sync_request_process_hang_wait = 1800
    @max_force_attempt_count = 5

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

    def self.batch_size
        @batch_size
    end

    def self.batch_size=(value)
        @batch_size = value
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


    # Elasticsearch index 名の先頭要素を設定する。
    # 空文字列は EMPTY_ES_INDEX_PREFIX へ置き換える。
    # 値を指定する場合は小文字英字で始まり、小文字英字とアンダーバーだけを許可する。
    def self.setup(index_prefix:, &block)
        raise ArgumentError, "setup にはクライアント生成のブロックが必要です" unless block
        raise ArgumentError, "setup にはindex_prefixが必要です" unless index_prefix

        index_prefix_string = index_prefix.to_s

        if index_prefix_string.empty? == false
            unless valid_es_index_name_element?(index_prefix_string)
                raise ArgumentError,
                    "index_prefix は小文字の英字で始まり、小文字の英字とアンダーバーだけを使用してください: #{index_prefix_string.inspect}"
            end
        end

        if index_prefix_string.include?(ES_INDEX_NAME_DELIMITER)
            raise ArgumentError,
                "index_prefix に #{ES_INDEX_NAME_DELIMITER.inspect} は使用できません"
        end

        @index_prefix = index_prefix_string
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

    # 設定済みの index_prefix を index 名へ使用できる文字列として返す。
    # 空文字列が設定されている場合も先頭要素を省略せず、代理値を返す。
    def self.index_prefix
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @index_prefix

        index_prefix_string = @index_prefix.to_s
        return EMPTY_ES_INDEX_PREFIX if index_prefix_string.empty?

        index_prefix_string
    end

    # 複数 target 検索のショートハンド。
    # query は Searcher の query_string として渡す。
    def self.multi_search(index_targets, query, **options)
        AreSearch::Searcher.search(
            index_targets,
            query_string: query,
            **options,
        )
    end

    # More Like This 検索のショートハンド。
    # instance と index_target は Searcher の MLT 用オプションとして渡す。
    def self.more_like_this(index_targets, instance, index_target, **options)
        AreSearch::Searcher.search(
            index_targets,
            mlt_instance:     instance,
            mlt_index_target: index_target,
            **options,
        )
    end

    def self.mark_index!(es_index_name)
        AreSearch::IndexMarker.create_manual!(es_index_name)
    end

    def self.unmark_index!(es_index_name)
        AreSearch::IndexMarker.delete_manual!(es_index_name)
    end
end
