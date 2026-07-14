# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch, "configuration" do
    around do |example|
        original_client_block = described_class.instance_variable_get(:@client_block)
        original_index_prefix = described_class.instance_variable_get(:@index_prefix)
        original_lock_dir = described_class.instance_variable_get(:@lock_dir)
        original_sync_request_delay = described_class.sync_request_delay
        original_max_retry_count = described_class.max_retry_count
        original_sync_request_process_hang_wait = described_class.sync_request_process_hang_wait
        original_max_force_attempt_count = described_class.max_force_attempt_count
        original_validate_es_data = described_class.validate_es_data
        original_after_commit_mode = described_class.after_commit_mode
        original_index_operation_enabled = described_class.index_operation_enabled
        original_analyzer_settings = described_class.analyzer_settings
        original_thread_client = Thread.current.thread_variable_get(:are_search_es_client)

        described_class.instance_variable_set(:@client_block, nil)
        described_class.instance_variable_set(:@index_prefix, nil)
        Thread.current.thread_variable_set(:are_search_es_client, nil)

        example.run
    ensure
        described_class.instance_variable_set(:@client_block, original_client_block)
        described_class.instance_variable_set(:@index_prefix, original_index_prefix)
        described_class.lock_dir = original_lock_dir
        described_class.sync_request_delay = original_sync_request_delay
        described_class.max_retry_count = original_max_retry_count
        described_class.sync_request_process_hang_wait = original_sync_request_process_hang_wait
        described_class.max_force_attempt_count = original_max_force_attempt_count
        described_class.validate_es_data = original_validate_es_data
        described_class.after_commit_mode = original_after_commit_mode
        described_class.index_operation_enabled = original_index_operation_enabled
        described_class.analyzer_settings = original_analyzer_settings
        Thread.current.thread_variable_set(:are_search_es_client, original_thread_client)
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

    it "空の index_prefix は代理値を返す" do
        described_class.setup(index_prefix: "") do
            double("client")
        end

        expect(described_class.index_prefix).to eq(AreSearch::EMPTY_ES_INDEX_PREFIX)
    end

    it "index_prefix に index 名の区切り文字は使用できない" do
        expect do
            described_class.setup(index_prefix: "app__test") do
                double("client")
            end
        end.to raise_error(ArgumentError, /index_prefix.*"__" は使用できません/)
    end

    it "index_prefix は小文字の英字で始まり小文字の英字とアンダーバーだけを許可する" do
        invalid_values = [
            "App",
            "app-test",
            "app2",
            "_app",
        ]

        invalid_values.each do |invalid_value|
            expect do
                described_class.setup(index_prefix: invalid_value) do
                    double("client")
                end
            end.to raise_error(
                ArgumentError,
                /index_prefix は小文字の英字で始まり、小文字の英字とアンダーバーだけを使用してください/,
            )
        end
    end

    it "index_prefix の小文字英字とアンダーバーを許可する" do
        described_class.setup(index_prefix: "app_test") do
            double("client")
        end

        expect(described_class.index_prefix).to eq("app_test")
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

    it "任意設定を変更できる" do
        analyzer_settings = { analyzer: {} }
        described_class.sync_request_delay = 30
        described_class.max_retry_count = 7
        described_class.sync_request_process_hang_wait = 600
        described_class.max_force_attempt_count = 7
        described_class.validate_es_data = false
        described_class.after_commit_mode = :job
        described_class.index_operation_enabled = false
        described_class.analyzer_settings = analyzer_settings
        described_class.lock_dir = "/tmp/are_search_spec"

        expect(described_class.sync_request_delay).to eq(30)
        expect(described_class.max_retry_count).to eq(7)
        expect(described_class.sync_request_process_hang_wait).to eq(600)
        expect(described_class.max_force_attempt_count).to eq(7)
        expect(described_class.validate_es_data).to eq(false)
        expect(described_class.after_commit_mode).to eq(:job)
        expect(described_class.index_operation_enabled).to eq(false)
        expect(described_class.analyzer_settings).to equal(analyzer_settings)
        expect(described_class.lock_dir).to eq("/tmp/are_search_spec")
    end

    it "lock_dir 未設定時は Rails.root/tmp/are_search を返す" do
        rails_root = double("rails_root")
        joined_path = double("joined_path", to_s: "/app/root/tmp/are_search")

        described_class.lock_dir = nil

        allow(Rails)
            .to receive(:root)
            .and_return(rails_root)

        expect(rails_root)
            .to receive(:join)
            .with("tmp", "are_search")
            .and_return(joined_path)

        expect(described_class.lock_dir).to eq("/app/root/tmp/are_search")
    end
end
