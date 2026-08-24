# frozen_string_literal: true

require "stringio"
require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch, "configuration" do
    around do |example|
        original_client_block = described_class.instance_variable_get(:@client_block)
        original_index_prefix = described_class.instance_variable_get(:@index_prefix)
        original_lock_dir = described_class.instance_variable_get(:@lock_dir)
        original_sync_request_delay = described_class.sync_request_delay
        original_max_sync_try_count = described_class.max_sync_try_count
        original_sync_request_process_hang_wait = described_class.sync_request_process_hang_wait
        original_max_force_try_count = described_class.max_force_try_count
        original_after_commit_mode = described_class.after_commit_mode
        original_search_failure_mode = described_class.search_failure_mode
        original_index_operation_enabled = described_class.index_operation_enabled
        original_rake_operation_enabled = described_class.rake_operation_enabled
        original_analyzer_settings = described_class.analyzer_settings
        original_search_body_policy = described_class.search_body_policy
        original_search_param_policy = described_class.search_param_policy
        original_database_specific = described_class.database_specific
        original_searchable_class_setting = described_class.searchable_class_setting
        original_thread_client = Thread.current.thread_variable_get(:are_search_client)
        original_thread_client_pid = Thread.current.thread_variable_get(:are_search_client_pid)

        described_class.instance_variable_set(:@client_block, nil)
        described_class.instance_variable_set(:@index_prefix, nil)
        Thread.current.thread_variable_set(:are_search_client, nil)
        Thread.current.thread_variable_set(:are_search_client_pid, nil)

        example.run
    ensure
        described_class.instance_variable_set(:@client_block, original_client_block)
        described_class.instance_variable_set(:@index_prefix, original_index_prefix)
        described_class.lock_dir = original_lock_dir
        described_class.sync_request_delay = original_sync_request_delay
        described_class.max_sync_try_count = original_max_sync_try_count
        described_class.sync_request_process_hang_wait = original_sync_request_process_hang_wait
        described_class.max_force_try_count = original_max_force_try_count
        described_class.after_commit_mode = original_after_commit_mode
        described_class.search_failure_mode = original_search_failure_mode
        described_class.index_operation_enabled = original_index_operation_enabled
        described_class.rake_operation_enabled = original_rake_operation_enabled
        described_class.analyzer_settings = original_analyzer_settings
        described_class.search_body_policy = original_search_body_policy
        described_class.search_param_policy = original_search_param_policy
        described_class.database_specific = original_database_specific
        described_class.searchable_class_setting = original_searchable_class_setting
        Thread.current.thread_variable_set(:are_search_client, original_thread_client)
        Thread.current.thread_variable_set(:are_search_client_pid, original_thread_client_pid)
    end

    it "setup は client 生成ブロック必須" do
        expect do
            described_class.setup(index_prefix: "test")
        end.to raise_error(ArgumentError, "setup にはクライアント生成のブロックが必要です")
    end

    it "setup は index_prefix 必須" do
        expect do
            described_class.setup(index_prefix: nil) do
                double("client")
            end
        end.to raise_error(ArgumentError, "setup にはindex_prefixが必要です")
    end

    it "空の index_prefix は拒否する" do
        expect do
            described_class.setup(index_prefix: "") do
                double("client")
            end
        end.to raise_error(ArgumentError, "不正な index_prefix 名です")
    end

    it "index_prefix に共通の名前規則を適用する" do
        expect do
            described_class.setup(index_prefix: "app__test") do
                double("client")
            end
        end.to raise_error(ArgumentError, "不正な index_prefix 名です")
    end

    it "index_prefix に予約名を指定できない" do
        expect do
            described_class.setup(index_prefix: "are_search_reserved_ar_model_class_name") do
                double("client")
            end
        end.to raise_error(ArgumentError, "不正な index_prefix 名です")
    end

    it "index_prefix は String で指定する" do
        expect do
            described_class.setup(index_prefix: :app_name) do
                double("client")
            end
        end.to raise_error(ArgumentError, "不正な index_prefix 名です")
    end

    it "index_prefix に小文字英数字と単一のアンダーバーを使用できる" do
        described_class.setup(index_prefix: "app2_test3") do
            double("client")
        end

        expect(described_class.index_prefix).to eq("app2_test3")
    end

    it "setup 前に client を呼ぶと NotConfiguredError を出す" do
        expect do
            described_class.client
        end.to raise_error(AreSearch::NotConfiguredError, "AreSearch.setup が呼ばれていません")
    end

    it "setup 前に index_prefix を呼ぶと NotConfiguredError を出す" do
        expect do
            described_class.index_prefix
        end.to raise_error(AreSearch::NotConfiguredError, "AreSearch.setup が呼ばれていません")
    end

    it "search_body_policy は SearchBodyPolicy の継承クラスを受け付ける" do
        policy_class = Class.new(AreSearch::SearchBodyPolicy)

        described_class.search_body_policy = policy_class

        expect(described_class.search_body_policy).to equal(policy_class)
    end

    it "search_body_policy は基底クラスと無関係な値を拒否する" do
        invalid_values = [
            AreSearch::SearchBodyPolicy,
            Class.new,
            Object.new,
        ]

        invalid_values.each do |invalid_value|
            expect do
                described_class.search_body_policy = invalid_value
            end.to raise_error(
                ArgumentError,
                "search_body_policy は AreSearch::SearchBodyPolicy の継承クラスを指定してください",
            )
        end
    end

    it "search_param_policy は SearchParamPolicy の継承クラスを受け付ける" do
        policy_class = Class.new(AreSearch::SearchParamPolicy)

        described_class.search_param_policy = policy_class

        expect(described_class.search_param_policy).to equal(policy_class)
    end

    it "search_param_policy は基底クラスと無関係な値を拒否する" do
        invalid_values = [
            AreSearch::SearchParamPolicy,
            Class.new,
            Object.new,
        ]

        invalid_values.each do |invalid_value|
            expect do
                described_class.search_param_policy = invalid_value
            end.to raise_error(
                ArgumentError,
                "search_param_policy は AreSearch::SearchParamPolicy の継承クラスを指定してください",
            )
        end
    end

    it "database_specific は DatabaseSpecific の継承クラスを受け付ける" do
        database_specific_class = Class.new(AreSearch::DatabaseSpecific)

        described_class.database_specific = database_specific_class

        expect(described_class.database_specific).to equal(database_specific_class)
    end

    it "database_specific は基底クラスと無関係な値を拒否する" do
        invalid_values = [
            AreSearch::DatabaseSpecific,
            Class.new,
            Object.new,
        ]

        invalid_values.each do |invalid_value|
            expect do
                described_class.database_specific = invalid_value
            end.to raise_error(
                ArgumentError,
                "database_specific は AreSearch::DatabaseSpecific の継承クラスを指定してください",
            )
        end
    end

    it "searchable_class_setting を設定して取得できる" do
        setting = {
            "Article" => {
                default: {},
            },
        }

        described_class.searchable_class_setting = setting

        expect(described_class.searchable_class_setting).to equal(setting)
    end

    it "validate_searchable_class_setting! は設定全体をValidatorへ渡す" do
        setting = {
            "Article" => {
                default: {},
            },
        }
        described_class.searchable_class_setting = setting

        expect(AreSearch::SearchableValidator)
            .to receive(:validate_searchable_class_setting) do |actual_setting, errors|
                expect(actual_setting).to equal(setting)
                expect(errors).to eq([])
            end

        expect(described_class.validate_searchable_class_setting!).to eq(true)
    end

    it "validate_searchable_class_setting! はValidatorのエラーをArgumentErrorにする" do
        allow(AreSearch::SearchableValidator)
            .to receive(:validate_searchable_class_setting) do |_setting, errors|
                errors << "first error"
                errors << "second error"
            end

        expect do
            described_class.validate_searchable_class_setting!
        end.to raise_error(ArgumentError, "検索モデルのチェックに失敗しました\nfirst error\nsecond error\n\n")
    end

    it "client は同一スレッド内でキャッシュされる" do
        called_count = 0

        described_class.setup(index_prefix: "test") do
            called_count += 1
            double("client")
        end

        first_client = described_class.client
        second_client = described_class.client

        expect(first_client).to equal(second_client)
        expect(called_count).to eq(1)
    end

    it "fork後に継承したclientは再生成する" do
        called_count = 0
        inherited_client = double("inherited_client")

        described_class.setup(index_prefix: "test") do
            called_count += 1
            double("new_client")
        end

        Thread.current.thread_variable_set(
            :are_search_client,
            inherited_client,
        )
        Thread.current.thread_variable_set(
            :are_search_client_pid,
            Process.pid - 1,
        )

        client = described_class.client

        expect(client).not_to equal(inherited_client)
        expect(called_count).to eq(1)
        expect(
            Thread.current.thread_variable_get(:are_search_client_pid),
        ).to eq(Process.pid)
    end

    it "after_commit_modeは定義済みの値だけを受け付ける" do
        [:job, :direct, :none].each do |mode|
            described_class.after_commit_mode = mode

            expect(described_class.after_commit_mode).to eq(mode)
        end

        expect do
            described_class.after_commit_mode = :invalid
        end.to raise_error(
            ArgumentError,
            /after_commit_modeは: .* のいずれかで指定してください/,
        )
    end

    it "search_failure_modeは定義済みの値だけを受け付ける" do
        [:empty_result, :raise].each do |mode|
            described_class.search_failure_mode = mode

            expect(described_class.search_failure_mode).to eq(mode)
        end

        expect do
            described_class.search_failure_mode = :invalid
        end.to raise_error(
            ArgumentError,
            /search_failure_mode は .* のいずれかで指定してください/,
        )
    end

    it "任意設定を変更できる" do
        analyzer_settings = { analysis: {} }
        described_class.sync_request_delay = 30
        described_class.max_sync_try_count = 7
        described_class.sync_request_process_hang_wait = 600
        described_class.max_force_try_count = 7
        described_class.after_commit_mode = :job
        described_class.index_operation_enabled = false
        described_class.rake_operation_enabled = true
        described_class.analyzer_settings = analyzer_settings
        described_class.lock_dir = "/tmp/are_search_spec"

        expect(described_class.sync_request_delay).to eq(30)
        expect(described_class.max_sync_try_count).to eq(7)
        expect(described_class.sync_request_process_hang_wait).to eq(600)
        expect(described_class.max_force_try_count).to eq(7)
        expect(described_class.after_commit_mode).to eq(:job)
        expect(described_class.index_operation_enabled).to eq(false)
        expect(described_class.rake_operation_enabled).to eq(true)
        expect(described_class.analyzer_settings).to equal(analyzer_settings)
        expect(described_class.lock_dir).to eq("/tmp/are_search_spec")
    end

    it "analyzer_settings は analysis Hash 必須" do
        expect do
            described_class.analyzer_settings = { analyzer: {} }
        end.to raise_error(
            ArgumentError,
            "analyzer_settings は :analysis を持つ Hash を指定してください",
        )
    end

    it "rake_operation_enabled が false の場合は rake task の実行を拒否する" do
        described_class.rake_operation_enabled = false

        expect do
            described_class.validate_rake_operation_enabled!
        end.to raise_error(
            AreSearch::RakeOperationViolation,
            /rake_operation_enabled が false/,
        )
    end

    it "rake_operation_enabled が true の場合は rake task の実行を許可する" do
        described_class.rake_operation_enabled = true

        expect do
            described_class.validate_rake_operation_enabled!
        end.not_to raise_error
    end

    it "sync runner lock は lock_dir の sync_runner 配下を使用する" do
        described_class.lock_dir = "/tmp/are_search_spec"

        expect(
            described_class.sync_runner_lock_file_path,
        ).to eq(
            "/tmp/are_search_spec/sync_runner/sync_runner.lock",
        )
    end

    it "index lock のファイル名にはalias名だけを使用する" do
        described_class.lock_dir = "/tmp/are_search_spec"

        expect(
            described_class.index_lock_file_path("test__articles__default"),
        ).to eq(
            "/tmp/are_search_spec/index/test__articles__default.lock",
        )

        expect do
            described_class.index_lock_file_path("invalid/index")
        end.to raise_error(ArgumentError, "不正な Elasticsearch alias 名です")
    end

    it "lock_dir 未設定時は Rails.root/tmp/are_search/locks を返す" do
        rails_root = double("rails_root")
        joined_path = double("joined_path", to_s: "/app/root/tmp/are_search/locks")

        described_class.lock_dir = nil

        allow(Rails)
            .to receive(:root)
            .and_return(rails_root)

        expect(rails_root)
            .to receive(:join)
            .with("tmp", "are_search", "locks")
            .and_return(joined_path)

        expect(described_class.lock_dir).to eq("/app/root/tmp/are_search/locks")
    end
end

RSpec.describe AreSearch do
    it "has a version number" do
        expect(AreSearch::VERSION).not_to be nil
    end

    describe ".default_aggs_size" do
        it "aggs の Array 簡易形式で使用する bucket 数を返す" do
            expect(described_class.default_aggs_size).to eq(
                AreSearch::StandardBodyBuilder::DEFAULT_AGGS_SIZE,
            )
        end
    end

    describe "内部定義" do
        it "設定値の検査に使う定数を公開しない" do
            expect(described_class.const_defined?(:ANALYZER_SETTINGS, false)).to eq(false)
            expect(described_class.const_defined?(:DEFAULT_AGGS_SIZE, false)).to eq(false)

            expect do
                described_class::DEFAULT_ANALYZER_SETTINGS
            end.to raise_error(NameError)

            expect do
                described_class::AFTER_COMMIT_MODES
            end.to raise_error(NameError)

            expect do
                described_class::SEARCH_FAILURE_MODES
            end.to raise_error(NameError)
        end

        it "client 設定のログ出力メソッドを公開しない" do
            expect(described_class.respond_to?(:log_client_config)).to eq(false)
            expect(described_class.respond_to?(:log_client_config, true)).to eq(true)
        end

        it "client 設定ログには接続先だけを出して認証情報を含めない" do
            log_output = StringIO.new
            logger = ActiveSupport::Logger.new(log_output)
            logger.level = ::Logger::DEBUG

            client = Elasticsearch::Client.new(
                url: "https://elastic_user:elastic_password@example.com:9200",
                adapter: :net_http,
                transport_options: {
                    request: {
                        open_timeout: 2,
                        timeout:      10,
                    },
                    ssl: {
                        verify: false,
                    },
                },
            )

            connection_host = client.transport.connections.connections.first.host
            expect(connection_host[:user]).to eq("elastic_user")
            expect(connection_host[:password]).to eq("elastic_password")

            development_env = ActiveSupport::EnvironmentInquirer.new("development")
            allow(Rails)
                .to receive(:env)
                .and_return(development_env)
            allow(described_class)
                .to receive(:logger)
                .and_return(logger)

            described_class.send(:log_client_config, client)

            log_message = log_output.string

            expect(log_message).to include("[AreSearch] elasticsearch client created")
            expect(log_message).to include('scheme: "https"')
            expect(log_message).to include('host: "example.com"')
            expect(log_message).to include("port: 9200")
            expect(log_message).not_to include("elastic_user")
            expect(log_message).not_to include("elastic_password")
        end
    end

    describe ".query_type_combined_fields" do
        it "combined_fields の query_type を返す" do
            expect(described_class.query_type_combined_fields).to eq(
                AreSearch::StandardQueryBuilder::TYPE_COMBINED_FIELDS,
            )
        end
    end

    describe ".query_type_simple_query_string" do
        it "simple_query_string の query_type を返す" do
            expect(described_class.query_type_simple_query_string).to eq(
                AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
            )
        end
    end

    describe ".join_index_name" do
        it "index 名の要素を AreSearch の区切り文字で連結する" do
            result = described_class.join_index_name(
                "test",
                "articles",
                "*",
            )

            expect(result).to eq("test__articles__*")
        end
    end

    describe ".delete_physical_index!" do
        around do |example|
            original_index_operation_enabled = described_class.index_operation_enabled
            described_class.index_operation_enabled = true

            example.run
        ensure
            described_class.index_operation_enabled = original_index_operation_enabled
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            described_class.index_operation_enabled = false

            expect(AreSearch::IndexManager)
                .not_to receive(:delete_physical_index!)

            expect do
                described_class.delete_physical_index!(
                    "test__articles__default__2026_07_04_10_00_00_000000",
                )
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end

        it "物理 index 名でなければ拒否する" do
            expect(AreSearch::IndexManager)
                .not_to receive(:delete_physical_index!)

            expect do
                described_class.delete_physical_index!(
                    "test__articles__default",
                )
            end.to raise_error(ArgumentError, "不正な物理 index 名です")
        end

        it "物理 index の削除を IndexManager へ委譲する" do
            physical_index_name =
                "test__articles__default__2026_07_04_10_00_00_000000"

            expect(AreSearch::IndexManager)
                .to receive(:delete_physical_index!)
                .with(physical_index_name)
                .and_return(:deleted)

            result = described_class.delete_physical_index!(
                physical_index_name,
            )

            expect(result).to eq(:deleted)
        end
    end
end

RSpec.describe AreSearch::DatabaseSpecific do
    describe ".next_request_sequence" do
        it "継承クラスが実装しなければ例外にする" do
            database_specific_class = Class.new(described_class)

            expect do
                database_specific_class.next_request_sequence
            end.to raise_error(
                NotImplementedError,
                /next_request_sequence を実装してください/,
            )
        end
    end

    describe ".upsert" do
        it "継承クラスが実装しなければ例外にする" do
            database_specific_class = Class.new(described_class)

            expect do
                database_specific_class.upsert(
                    ar_model_class_name: "Article",
                    index_target_name:   :default,
                    ar_instance_key:     "123",
                    index_alias_name:       "test__articles__default",
                    sync_stage_name:          "default",
                    request_sequence:    42,
                    request_sequence_at: Time.zone.now,
                )
            end.to raise_error(
                NotImplementedError,
                /upsert を実装してください/,
            )
        end
    end
end

RSpec.describe AreSearch::PostgreSQLDatabaseSpecific do
    describe ".upsert" do
        it "同期要求を一意キーでupsertする" do
            request_sequence_at = Time.zone.now

            expect(AreSearch::SyncRequest)
                .to receive(:upsert)
                .with(
                    {
                        ar_model_class_name: "Article",
                        index_target_name:   :default,
                        ar_instance_key:     "123",
                        index_alias_name:       "test__articles__default",
                        sync_stage_name:          "default",
                        request_sequence:    42,
                        request_sequence_at: request_sequence_at,
                    },
                    unique_by: [:index_alias_name, :sync_stage_name, :ar_instance_key],
                )

            described_class.upsert(
                ar_model_class_name: "Article",
                index_target_name:   :default,
                ar_instance_key:     "123",
                index_alias_name:       "test__articles__default",
                sync_stage_name:          "default",
                request_sequence:    42,
                request_sequence_at: request_sequence_at,
            )
        end
    end
end

RSpec.describe AreSearch::SearchableValidator do
    it "利用側定義名の検査を公開しない" do
        expect(described_class.respond_to?(:valid_definition_name?)).to eq(false)
        expect(described_class.respond_to?(:definition_name_format_description)).to eq(false)
    end
end

RSpec.describe AreSearch::EsAdapter do
    let(:indices) { double("indices") }
    let(:client) { double("client", indices: indices) }

    before do
        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
    end

    describe ".index_alias_exists?" do
        let(:index_alias_name) do
            "test__articles__default"
        end


        it "Elasticsearchがtrue以外を返してもfalseへ正規化する" do
            expect(indices)
                .to receive(:exists_alias)
                .with(name: index_alias_name)
                .and_return(nil)

            result = described_class.index_alias_exists?(
                index_alias_name: index_alias_name,
            )

            expect(result).to eq(false)
        end
    end

    describe ".update_alias" do
        let(:new_physical_index_name) do
            "test__articles__default__2026_08_04_12_00_00_000000"
        end

        it "旧物理index名はArrayで指定する" do
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.update_alias(
                    old_physical_index_names: "test__articles__default__2026_08_03_12_00_00_000000",
                    new_physical_index_name:  new_physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "old_physical_index_names は Array で指定してください",
            )
        end

        it "新旧物理indexのalias名が一致しなければ拒否する" do
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.update_alias(
                    old_physical_index_names: [
                        "test__articles__archive__2026_08_03_12_00_00_000000",
                    ],
                    new_physical_index_name: new_physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "old_physical_index_names と new_physical_index_name の alias 名が一致しません",
            )
        end

        it "旧物理indexのremoveと新物理indexのaddを送信して成功を返す" do
            old_physical_index_names = [
                "test__articles__default__2026_08_02_12_00_00_000000",
                "test__articles__default__2026_08_03_12_00_00_000000",
            ]

            expect(indices)
                .to receive(:update_aliases)
                .with(
                    body: {
                        actions: [
                            {
                                remove: {
                                    index: old_physical_index_names[0],
                                    alias: "test__articles__default",
                                },
                            },
                            {
                                remove: {
                                    index: old_physical_index_names[1],
                                    alias: "test__articles__default",
                                },
                            },
                            {
                                add: {
                                    index: new_physical_index_name,
                                    alias: "test__articles__default",
                                },
                            },
                        ],
                    },
                )
                .and_return(
                    "acknowledged" => true,
                    "errors"       => false,
                )

            expect(indices).not_to receive(:get_alias)

            result = described_class.update_alias(
                old_physical_index_names: old_physical_index_names,
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.success)
        end

        it "alias更新APIがaction失敗を返した場合は失敗を返す" do
            allow(indices)
                .to receive(:update_aliases)
                .and_return(
                    "acknowledged"   => true,
                    "errors"         => true,
                    "action_results" => [],
                )

            expect(indices).not_to receive(:get_alias)

            result = described_class.update_alias(
                old_physical_index_names: [],
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.not_success)
        end

        it "alias更新APIの応答で成否不明でも新物理indexだけを指していれば成功を返す" do
            allow(indices)
                .to receive(:update_aliases)
                .and_return("acknowledged" => false)

            expect(indices)
                .to receive(:get_alias)
                .with(name: "test__articles__default")
                .and_return(
                    new_physical_index_name => {
                        "aliases" => {
                            "test__articles__default" => {},
                        },
                    },
                )

            result = described_class.update_alias(
                old_physical_index_names: [],
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.success)
        end

        it "alias更新APIの応答で成否不明かつ接続先が一致しなければ失敗を返す" do
            allow(indices)
                .to receive(:update_aliases)
                .and_return("acknowledged" => false)

            expect(indices)
                .to receive(:get_alias)
                .with(name: "test__articles__default")
                .and_return(
                    "test__articles__default__2026_08_03_12_00_00_000000" => {
                        "aliases" => {
                            "test__articles__default" => {},
                        },
                    },
                )

            result = described_class.update_alias(
                old_physical_index_names: [],
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.not_success)
        end
    end
end
