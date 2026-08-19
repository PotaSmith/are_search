# frozen_string_literal: true

require "elasticsearch"

require "fileutils"
require "securerandom"

require_relative "are_search/errors"
require_relative "are_search/version"
require_relative "are_search/es_adapter"

require_relative "are_search/index_definition"
require_relative "are_search/sync_lock"
require_relative "are_search/index_manager"
require_relative "are_search/index_target"
require_relative "are_search/reindexer"
require_relative "are_search/bulk_indexer"

require_relative "are_search/index_data_validator"
require_relative "are_search/searchable_validator"
require_relative "are_search/database_specific"
require_relative "are_search/postgresql_database_specific"
require_relative "are_search/searchable"
require_relative "are_search/sync_request"
require_relative "are_search/sync_request_boundary_target"
require_relative "are_search/sync_request_runner"
require_relative "are_search/sync_job"

require_relative "are_search/searcher/search_result"
require_relative "are_search/searcher/searcher_utils"
require_relative "are_search/searcher/search_body_policy"
require_relative "are_search/searcher/script_deny_search_body_policy"

require_relative "are_search/searcher/validator/search_option_context"
require_relative "are_search/searcher/validator/search_option_definition"
require_relative "are_search/searcher/validator/search_option_validator"
require_relative "are_search/searcher/validator/search_param_validator"

require_relative "are_search/searcher/validator/search_param_policy"
require_relative "are_search/searcher/validator/search_param_length_policy"

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
    @search_body_policy = AreSearch::ScriptDenySearchBodyPolicy
    @search_param_policy = AreSearch::SearchParamLengthPolicy
    @search_failure_mode = :empty_result
    @database_specific = AreSearch::PostgreSQLDatabaseSpecific
    @searchable_class_setting = {}
    @client_block = nil
    @index_prefix = nil
    @sync_request_delay = 120
    @max_sync_try_count = 100
    @lock_dir = nil
    @logger = nil
    @after_commit_mode = :direct
    @index_operation_enabled = false
    @rake_operation_enabled = false
    @batch_size = 500

    @sync_request_process_hang_wait = 1800
    @max_force_try_count = 5


    def self.analyzer_settings
        @analyzer_settings
    end

    def self.analyzer_settings=(value)
        @analyzer_settings = value
    end

    def self.search_body_policy
        @search_body_policy
    end

    # Elasticsearch へ送信するbodyと field 名を検査する policy を設定する。
    # SearchBodyPolicy 自体ではなく、その継承クラスだけを受け付ける。
    def self.search_body_policy=(policy_class)
        valid_policy_class = policy_class.instance_of?(Class)

        if valid_policy_class
            valid_policy_class = policy_class < AreSearch::SearchBodyPolicy
        end

        unless valid_policy_class
            raise ArgumentError, "search_body_policy は AreSearch::SearchBodyPolicy の継承クラスを指定してください"
        end

        @search_body_policy = policy_class
    end

    def self.search_param_policy
        @search_param_policy
    end

    # Elasticsearch へ送信する param の値を検査する policy を設定する。
    # SearchParamPolicy 自体ではなく、その継承クラスだけを受け付ける。
    def self.search_param_policy=(policy_class)
        valid_policy_class = policy_class.instance_of?(Class)

        if valid_policy_class
            valid_policy_class = policy_class < AreSearch::SearchParamPolicy
        end

        unless valid_policy_class
            raise ArgumentError, "search_param_policy は AreSearch::SearchParamPolicy の継承クラスを指定してください"
        end

        @search_param_policy = policy_class
    end

    # 検索を実行できない場合に、空結果を返すか例外を送出するかを返す。
    def self.search_failure_mode
        @search_failure_mode
    end

    # 検索を実行できない場合の扱いを設定する。
    def self.search_failure_mode=(value)
        unless SEARCH_FAILURE_MODES.include?(value)
            raise ArgumentError, "search_failure_mode は #{SEARCH_FAILURE_MODES.inspect} のいずれかで指定してください"
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
            raise ArgumentError, "database_specific は AreSearch::DatabaseSpecific の継承クラスを指定してください"
        end

        @database_specific = database_specific_class
    end

    # SearchableモデルのIndexTarget・sync stage構成を返す。
    def self.searchable_class_setting
        @searchable_class_setting
    end

    # SearchableモデルのIndexTarget・sync stage構成を設定する。
    def self.searchable_class_setting=(value)
        @searchable_class_setting = value
    end

    # searchable_class_setting 全体を検査する。呼び出し時期は利用側で決める。
    def self.validate_searchable_class_setting!
        errors = []
        AreSearch::SearchableValidator.validate_searchable_class_setting(searchable_class_setting, errors)

        unless errors.empty?
            raise ArgumentError, "検索モデルのチェックに失敗しました\n" + errors.join("\n") + "\n\n"
        end

        true
    end

    def self.sync_request_delay
        @sync_request_delay
    end

    def self.sync_request_delay=(value)
        @sync_request_delay = value
    end

    def self.max_sync_try_count
        @max_sync_try_count
    end

    def self.max_sync_try_count=(value)
        @max_sync_try_count = value
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

    def self.validate_index_operation_enabled!
        return if AreSearch.index_operation_enabled

        message = "[AreSearch] index 操作が許可されていません。AreSearch.index_operation_enabled が false になっています。"

        raise AreSearch::IndexOperationViolation, message
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

        message = "[AreSearch] rake task の実行が許可されていません。AreSearch.rake_operation_enabled が false になっています。"

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

    def self.max_force_try_count
        @max_force_try_count
    end

    def self.max_force_try_count=(value)
        @max_force_try_count = value
    end

    # ロックファイル類のベースディレクトリ。
    # 配下に locks/sync_runner/ と locks/index/ をgem側の規約で作る。
    # 未設定の場合は Rails.root/tmp/are_search/locks を使う。
    # Rails.root に依存するため即値ではなく参照時に遅延評価する。
    def self.lock_dir
        @lock_dir || Rails.root.join("tmp", "are_search", "locks").to_s
    end

    def self.lock_dir=(value)
        @lock_dir = value
    end

    # run_sync_requests rake タスクの多重起動を防ぐためのロックファイルパス。
    # lock_dir/sync_runner/sync_runner.lock
    def self.sync_runner_lock_file_path
        File.join(lock_dir, "sync_runner", "sync_runner.lock")
    end

    # index作成中、reindex、clean_up の多重起動防止用 flock ファイルパス（IndexTarget単位）。
    # lock_dir/index/{index_alias_name}.lock
    def self.index_lock_file_path(index_alias_name)
        AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

        File.join(lock_dir, "index", "#{index_alias_name}.lock")
    end

    # Elasticsearch index 名の先頭要素を設定する。
    # 値を指定する場合は利用側定義名の共通形式で検査する。
    def self.setup(index_prefix:, &block)
        raise ArgumentError, "setup にはクライアント生成のブロックが必要です" unless block
        raise ArgumentError, "setup にはindex_prefixが必要です" unless index_prefix

        AreSearch::IndexDefinition.valid_index_prefix!(index_prefix)

        @index_prefix = index_prefix
        @client_block = block
    end

    def self.log_client_config(client)
        return if Rails.env.test?
        return unless AreSearch.logger.debug?

        client.transport.connections.connections.each do |connection|
            faraday_connection = connection.connection
            adapter = faraday_connection.builder.adapter
            host = connection.host
            log_host = {
                scheme: host[:scheme],
                host:   host[:host],
                port:   host[:port],
                path:   host[:path],
            }

            AreSearch.logger.debug do
                "[AreSearch] elasticsearch client created " \
                    "host=#{log_host.inspect} " \
                    "adapter=#{adapter.inspect} " \
                    "open_timeout=#{faraday_connection.options.open_timeout.inspect} " \
                    "timeout=#{faraday_connection.options.timeout.inspect} " \
                    "ssl_verify=#{faraday_connection.ssl.verify.inspect}"
            end
        end
    rescue StandardError => e
        AreSearch.logger.error do
            "[AreSearch] elasticsearch client config inspect failed: #{e.class}: #{e.message}"
        end
    end
    private_class_method :log_client_config

    def self.client
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @client_block

        cached_client = Thread.current.thread_variable_get(:are_search_client)
        cached_pid = Thread.current.thread_variable_get(:are_search_client_pid)

        if cached_client != nil && cached_pid == Process.pid
            return cached_client
        end

        new_client = @client_block.call
        log_client_config(new_client)

        Thread.current.thread_variable_set(:are_search_client, new_client)
        Thread.current.thread_variable_set(:are_search_client_pid, Process.pid)

        new_client
    end

    def self.index_prefix
        raise NotConfiguredError, "AreSearch.setup が呼ばれていません" unless @index_prefix

        @index_prefix
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
    def self.join_index_name(*elements)
        elements.join(AreSearch::IndexDefinition::INDEX_NAME_DELIMITER)
    end

    # 指定した物理 index を削除する。
    # index lock や sync lock は取得せず、IndexManager の低レベル削除処理へ委譲する。
    def self.delete_physical_index!(physical_index_name)
        AreSearch.validate_index_operation_enabled!

        AreSearch::IndexDefinition.valid_physical_index_name!(
            physical_index_name,
        )

        AreSearch::IndexManager.delete_physical_index!(physical_index_name)
    end
end
