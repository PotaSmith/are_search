# frozen_string_literal: true

require "fileutils"
require "securerandom"

require_relative "are_search/errors"
require_relative "are_search/version"

require_relative "are_search/index_definition"
require_relative "are_search/index_marker"
require_relative "are_search/index_manager"
require_relative "are_search/index_target"
require_relative "are_search/reindexer"

require_relative "are_search/es_data_validator"
require_relative "are_search/database_specific"
require_relative "are_search/postgresql_database_specific"
require_relative "are_search/searchable"
require_relative "are_search/sync_request"
require_relative "are_search/record_sync"
require_relative "are_search/sync_job"

require_relative "are_search/searcher/search_result"
require_relative "are_search/searcher/searcher_utils"
require_relative "are_search/searcher/es_search_body_policy"
require_relative "are_search/searcher/script_deny_es_search_body_policy"

require_relative "are_search/searcher/validator/search_option_context"
require_relative "are_search/searcher/validator/search_option_definition"
require_relative "are_search/searcher/validator/search_option_validator"
require_relative "are_search/searcher/validator/search_param_validator"

require_relative "are_search/searcher/query_builder/query_builder_base"
require_relative "are_search/searcher/query_builder/standard_query_builder"
require_relative "are_search/searcher/query_builder/more_like_this_query_builder"
require_relative "are_search/searcher/query_builder/raw_query_builder"
require_relative "are_search/searcher/query_builder_selector"

require_relative "are_search/searcher/body_builder/body_builder_base"
require_relative "are_search/searcher/body_builder/standard_body_builder"
require_relative "are_search/searcher/body_builder/raw_body_builder"
require_relative "are_search/searcher/body_builder_selector"

require_relative "are_search/searcher"


require_relative "are_search/rake_utils" if defined?(Rails::Railtie)
require_relative "are_search/railtie" if defined?(Rails::Railtie)

module AreSearch

    # CJK Bigram + Unigram アナライザ設定
    # Solrの CJKBigramFilterFactory outputUnigrams="true" と等価
    DEFAULT_ANALYZER_SETTINGS = {
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

    SEARCH_FAILURE_MODES = [
        :empty_result,
        :raise,
    ].freeze

    private_constant :DEFAULT_ANALYZER_SETTINGS
    private_constant :AFTER_COMMIT_MODES
    private_constant :SEARCH_FAILURE_MODES

    @analyzer_settings = DEFAULT_ANALYZER_SETTINGS
    @es_search_body_policy = AreSearch::ScriptDenyEsSearchBodyPolicy
    @search_failure_mode = :empty_result
    @database_specific = AreSearch::PostgreSQLDatabaseSpecific
    @client_block = nil
    @index_prefix = nil
    @sync_request_delay = 120
    @max_retry_count = 100
    @lock_dir = nil
    @logger = nil
    @after_commit_mode = :direct
    @index_operation_enabled = false
    @rake_operation_enabled = false
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

    def self.es_search_body_policy
        @es_search_body_policy
    end

    # Elasticsearchへ送信するbodyとfield名を検査するpolicyを設定する。
    # EsSearchBodyPolicy自体ではなく、その継承クラスだけを受け付ける。
    def self.es_search_body_policy=(policy_class)
        valid_policy_class = policy_class.instance_of?(Class)

        if valid_policy_class
            valid_policy_class = policy_class < AreSearch::EsSearchBodyPolicy
        end

        unless valid_policy_class
            raise ArgumentError,
                "es_search_body_policy は AreSearch::EsSearchBodyPolicy の継承クラスを指定してください"
        end

        @es_search_body_policy = policy_class
    end

    # 検索を実行できない場合に、空結果を返すか例外を送出するかを返す。
    def self.search_failure_mode
        @search_failure_mode
    end

    # 検索を実行できない場合の扱いを設定する。
    def self.search_failure_mode=(value)
        unless SEARCH_FAILURE_MODES.include?(value)
            raise ArgumentError,
                "search_failure_mode は #{SEARCH_FAILURE_MODES.inspect} のいずれかで指定してください"
        end

        @search_failure_mode = value
    end

    def self.database_specific
        @database_specific
    end

    # AreSearch が使用するDB固有処理を設定する。
    # DatabaseSpecific自体ではなく、その継承クラスだけを受け付ける。
    def self.database_specific=(database_specific_class)
        valid_database_specific_class = database_specific_class.instance_of?(Class)

        if valid_database_specific_class
            valid_database_specific_class = database_specific_class < AreSearch::DatabaseSpecific
        end

        unless valid_database_specific_class
            raise ArgumentError,
                "database_specific は AreSearch::DatabaseSpecific の継承クラスを指定してください"
        end

        @database_specific = database_specific_class
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

    # sync request を回収する rake task の実行を許可しているか返す。
    def self.rake_operation_enabled
        @rake_operation_enabled
    end

    # sync request を回収する rake task の実行可否を設定する。
    def self.rake_operation_enabled=(value)
        @rake_operation_enabled = value
    end

    # sync request を回収する rake task の実行環境か確認する。
    def self.validate_rake_operation_enabled!
        return if rake_operation_enabled

        message = "[AreSearch] rake task の実行が許可されていません。" \
            "AreSearch.rake_operation_enabled が false になっています。"

        raise AreSearch::RakeOperationViolation, message
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
    # 空文字列は AreSearch::IndexDefinition::EMPTY_ES_INDEX_PREFIX へ置き換える。
    # 値を指定する場合は小文字英字で始まり、小文字英字とアンダーバーだけを許可する。
    def self.setup(index_prefix:, &block)
        raise ArgumentError, "setup にはクライアント生成のブロックが必要です" unless block
        raise ArgumentError, "setup にはindex_prefixが必要です" unless index_prefix

        index_prefix_string = index_prefix.to_s

        if index_prefix_string.empty? == false
            unless AreSearch::IndexDefinition.valid_es_index_name_element?(index_prefix_string)
                raise ArgumentError,
                    "index_prefix は小文字の英字で始まり、小文字の英字とアンダーバーだけを使用してください: #{index_prefix_string.inspect}"
            end
        end

        if index_prefix_string.include?(AreSearch::IndexDefinition::ES_INDEX_NAME_DELIMITER)
            raise ArgumentError,
                "index_prefix に #{AreSearch::IndexDefinition::ES_INDEX_NAME_DELIMITER.inspect} は使用できません"
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
    private_class_method :log_client_config

    def self.client
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @client_block

        cached_client = Thread.current.thread_variable_get(:are_search_es_client)
        cached_pid = Thread.current.thread_variable_get(:are_search_es_client_pid)

        if cached_client != nil && cached_pid == Process.pid
            return cached_client
        end

        new_client = @client_block.call
        log_client_config(new_client)

        Thread.current.thread_variable_set(:are_search_es_client, new_client)
        Thread.current.thread_variable_set(:are_search_es_client_pid, Process.pid)

        new_client
    end

    # 設定済みの index_prefix を index 名へ使用できる文字列として返す。
    # 空文字列が設定されている場合も先頭要素を省略せず、代理値を返す。
    def self.index_prefix
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @index_prefix

        index_prefix_string = @index_prefix.to_s
        return AreSearch::IndexDefinition::EMPTY_ES_INDEX_PREFIX if index_prefix_string.empty?

        index_prefix_string
    end

    # aggs の Array 簡易形式で使用する bucket 数を返す。
    def self.default_aggs_size
        AreSearch::StandardBodyBuilder::DEFAULT_AGGS_SIZE
    end

    # 標準検索で combined_fields を使用する query_type を返す。
    def self.query_type_combined_fields
        AreSearch::StandardQueryBuilder::TYPE_COMBINED_FIELDS
    end

    # 標準検索で simple_query_string を使用する query_type を返す。
    def self.query_type_simple_query_string
        AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING
    end

    # Elasticsearch index 名の要素を、AreSearch の区切り文字で連結する。
    # ワイルドカードを含む検索パターンにも使用するため、要素の妥当性は検査しない。
    def self.join_es_index_name(*elements)
        elements.join(AreSearch::IndexDefinition::ES_INDEX_NAME_DELIMITER)
    end

    # 指定した物理 index を削除する。
    # lock や marker は取得せず、IndexManager の低レベル削除処理へ委譲する。
    def self.delete_physical_index!(physical_es_index_name)
        AreSearch::IndexManager.es_delete_index!(physical_es_index_name)
    end

    def self.mark_index!(es_index_name)
        AreSearch::IndexMarker.create_manual!(es_index_name)
    end

    def self.unmark_index!(es_index_name)
        AreSearch::IndexMarker.delete_manual!(es_index_name)
    end
end
