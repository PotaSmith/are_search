# frozen_string_literal: true

require "spec_helper"

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
        original_index_operation_enabled = described_class.index_operation_enabled
        original_rake_operation_enabled = described_class.rake_operation_enabled
        original_analyzer_settings = described_class.analyzer_settings
        original_search_body_policy = described_class.search_body_policy
        original_search_param_policy = described_class.search_param_policy
        original_database_specific = described_class.database_specific
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
        described_class.index_operation_enabled = original_index_operation_enabled
        described_class.rake_operation_enabled = original_rake_operation_enabled
        described_class.analyzer_settings = original_analyzer_settings
        described_class.search_body_policy = original_search_body_policy
        described_class.search_param_policy = original_search_param_policy
        described_class.database_specific = original_database_specific
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

    it "任意設定を変更できる" do
        analyzer_settings = { analyzer: {} }
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

    it "sync lock は lock_dir の sync 配下を使用する" do
        described_class.lock_dir = "/tmp/are_search_spec"

        expect(
            described_class.sync_lock_file_path,
        ).to eq(
            "/tmp/are_search_spec/sync/sync.lock",
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
