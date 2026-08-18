# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"
require "tmpdir"
require_relative "../support/integration_support"

RSpec.describe "AreSearch check index status rake integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_lock_dir = AreSearch.lock_dir
        original_rake_application = Rake.application

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true

        clear_are_search_integration_records([DocumentFirst, DocumentSecond])
        clear_index_status_indices

        Dir.mktmpdir("are_search_index_status_integration") do |dir|
            AreSearch.lock_dir = dir
            load_index_status_rake_tasks
            example.run
        end
    ensure
        clear_are_search_integration_records([DocumentFirst, DocumentSecond])
        clear_index_status_indices

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.lock_dir = original_lock_dir
        Rake.application = original_rake_application
    end

    # check_index_status が対象にする DocumentFirst の alias 名を返す。
    def index_alias_name
        document_first_index_target.are_search_index_alias_name
    end

    # 指定alias用のtimestamp付き物理index名を返す。
    def physical_index_name(sequence)
        "#{index_alias_name}__2026_08_11_21_30_00_#{format('%06d', sequence)}"
    end

    # 別target用のtimestamp付き物理index名を返す。
    def other_target_physical_index_name
        AreSearch.join_index_name(
            AreSearch.index_prefix,
            "document_firsts",
            "archive",
        ) + "__2026_08_11_21_30_00_000001"
    end

    # AreSearch形式外でalias接続確認に使う物理index名を返す。
    def external_physical_index_name
        "#{AreSearch.index_prefix}__external_current"
    end

    # 実Elasticsearchへ空のindexを作成する。
    def create_index(index_name)
        AreSearch.client.indices.create(index: index_name)
    end

    # 指定物理indexへDocumentFirstのaliasを追加する。
    def add_alias(index_name)
        AreSearch.client.indices.update_aliases(
            body: {
                actions: [
                    {
                        add: {
                            index: index_name,
                            alias: index_alias_name,
                        },
                    },
                ],
            },
        )
    end

    # 指定indexを削除する。存在しない場合は何もしない。
    def delete_index(index_name)
        AreSearch.client.indices.delete(index: index_name)
    rescue Elastic::Transport::Transport::Errors::NotFound
        nil
    end

    # check_index_status用に作成したindexを削除する。
    def clear_index_status_indices
        target_alias_names = [
            DocumentFirst.are_search_index_target(:default).are_search_index_alias_name,
            DocumentSecond.are_search_index_target(:default).are_search_index_alias_name,
        ]

        target_alias_names.each do |target_alias_name|
            current_names = AreSearch::EsAdapter.indices_get_alias(
                index_alias_name: target_alias_name,
            ).keys
            physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: target_alias_name,
            ).keys

            (current_names + physical_names).uniq.each do |index_name|
                delete_index(index_name)
            end

            delete_index(target_alias_name)
        end

        delete_index(other_target_physical_index_name)
        delete_index(external_physical_index_name)
    end

    # check_index_status rake taskを独立したRake applicationへ読み込む。
    def load_index_status_rake_tasks
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        gem_root = Gem.loaded_specs.fetch("are_search").full_gem_path
        load File.join(gem_root, "lib", "tasks", "are_search.rake")
    end

    # Elasticsearchが保持するindex.creation_dateをepoch millisecondで返す。
    def index_creation_date(index_name)
        response = AreSearch.client.indices.get(index: index_name)
        creation_date = response.dig(
            index_name,
            "settings",
            "index",
            "creation_date",
        )

        raise "creation_date not found: #{index_name}" if creation_date.nil?

        creation_date.to_i
    end

    # check_index_statusの表示と同じUTC ISO8601形式へ変換する。
    def index_creation_date_text(index_name)
        creation_date = index_creation_date(index_name)
        Time.at(creation_date / 1000.0).utc.iso8601(6)
    end

    # rake task の標準出力を文字列として返す。
    def run_check_index_status
        output = StringIO.new
        original_stdout = $stdout
        $stdout = output

        Rake::Task["are_search:check_index_status"].invoke

        output.string
    ensure
        $stdout = original_stdout
    end

    # 全出力からDocumentFirstの状態表示だけを返す。
    def document_first_status_output(output)
        status_header = "[AreSearch] index status: #{index_alias_name}"
        start_position = output.index(status_header)
        raise "DocumentFirst status not found" if start_position.nil?

        next_position = output.index("[AreSearch] index status:", start_position + status_header.length)
        return output[start_position..] if next_position.nil?

        output[start_position...next_position]
    end

    it "実aliasと複数sync lockとlockの状態を出力する" do
        current_name = physical_index_name(1)
        create_index(current_name)
        add_alias(current_name)

        AreSearch::SyncLock.create!(
            index_alias_name: index_alias_name,
            sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            operation:        "reindex",
            owner_token:      SecureRandom.uuid,
            owner_host:       "test-host",
            owner_pid:        12345,
            started_at:       Time.zone.now,
        )
        AreSearch::SyncLock.create!(
            index_alias_name: index_alias_name,
            sync_stage_name:  "default",
            operation:        "manual",
            owner_token:      SecureRandom.uuid,
            owner_host:       "test-stage-host",
            owner_pid:        23456,
            started_at:       Time.zone.now,
        )

        lock_path = AreSearch.index_lock_file_path(index_alias_name)
        FileUtils.mkdir_p(File.dirname(lock_path))

        File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
            lock_file.flock(File::LOCK_EX)

            output = document_first_status_output(run_check_index_status)

            expect(output.scan(/sync lock:\s+exists/).length).to eq(2)
            expect(output).to include("sync_stage_name=\"#{AreSearch::SyncLock.index_target_lock_name}\"")
            expect(output).to include('sync_stage_name="default"')
            expect(output).to match(/lock:\s+locked/)
            expect(output).to match(/alias:\s+exists/)
            expect(output).to include(
                "current   - #{current_name} : creation_date #{index_creation_date_text(current_name)}",
            )
            expect(output).to match(/warning:\s+sync lock exists/)
        end
    end

    it "別targetの物理indexを状態確認から除外する" do
        current_name = physical_index_name(1)
        other_name = other_target_physical_index_name

        create_index(current_name)
        create_index(other_name)
        add_alias(current_name)

        output = document_first_status_output(run_check_index_status)

        expect(output).to include(
            "current   - #{current_name} : creation_date #{index_creation_date_text(current_name)}",
        )
        expect(output).not_to include(other_name)
        expect(output).to match(/warning:\s+none/)
    end

    it "aliasが無く物理indexだけ存在する場合はalias missingだけを警告する" do
        create_index(physical_index_name(1))

        output = document_first_status_output(run_check_index_status)

        expect(output).to match(/warning:\s+alias missing/)
        expect(output).not_to match(/warning:\s+physical index missing/)
    end

    it "aliasも物理indexも無い場合は両方のmissingを警告する" do
        output = document_first_status_output(run_check_index_status)

        expect(output).to match(/warning:\s+alias missing/)
        expect(output).to match(/warning:\s+physical index missing/)
    end

    it "alias名と同名の物理indexがある場合は重複を警告する" do
        create_index(index_alias_name)

        output = document_first_status_output(run_check_index_status)

        expect(output).to match(/warning:\s+alias missing/)
        expect(output).to match(/warning:\s+physical index with alias name exists/)
    end

    it "creation_dateが新しい物理indexがcurrentでない場合は警告する" do
        current_name = physical_index_name(2)
        newest_name = physical_index_name(1)

        create_index(current_name)
        sleep 0.02
        create_index(newest_name)
        add_alias(current_name)

        expect(index_creation_date(newest_name)).to be > index_creation_date(current_name)
        expect(newest_name).to be < current_name

        output = document_first_status_output(run_check_index_status)

        expect(output).to include(
            "current   - #{current_name} : creation_date #{index_creation_date_text(current_name)}",
        )
        expect(output).to include(
            "unaliased - #{newest_name} : creation_date #{index_creation_date_text(newest_name)}",
        )
        expect(output).to match(/warning:\s+newest physical index is not current/)
    end

    it "複数のcurrentにcreation_dateが最新の物理indexを含む場合は最新警告を出さない" do
        old_name = physical_index_name(2)
        newest_name = physical_index_name(1)

        create_index(old_name)
        sleep 0.02
        create_index(newest_name)
        add_alias(old_name)
        add_alias(newest_name)

        expect(index_creation_date(newest_name)).to be > index_creation_date(old_name)

        output = document_first_status_output(run_check_index_status)

        expect(output).to include(
            "current   - #{old_name} : creation_date #{index_creation_date_text(old_name)}",
        )
        expect(output).to include(
            "current   - #{newest_name} : creation_date #{index_creation_date_text(newest_name)}",
        )
        expect(output).not_to match(/warning:\s+newest physical index is not current/)
    end

    it "aliasがAreSearch形式外の物理indexを指す場合は接続先を表示して形式を警告する" do
        external_name = external_physical_index_name
        create_index(external_name)
        add_alias(external_name)

        output = document_first_status_output(run_check_index_status)

        expect(output).to match(/alias:\s+exists/)
        expect(output).to include(external_name)
        expect(output).to match(/physical indexes:\s+none/m)
        expect(output).to match(/warning:\s+current physical index is not AreSearch format/)
        expect(output).not_to match(/warning:\s+physical index missing/)
    end
end

RSpec.describe "AreSearch rake status operations integration", type: :model do
    include AreSearchIntegrationSupport

    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled
        original_rake_operation_enabled = AreSearch.rake_operation_enabled
        original_rake_application = Rake.application
        original_stdin = $stdin

        AreSearch.after_commit_mode = :none
        AreSearch.index_operation_enabled = true
        AreSearch.rake_operation_enabled = true

        clear_rake_status_state
        rebuild_rake_status_indexes
        load_are_search_rake_tasks

        example.run
    ensure
        $stdin = original_stdin
        clear_rake_status_state

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
        AreSearch.rake_operation_enabled = original_rake_operation_enabled
        Rake.application = original_rake_application
    end

    # rake taskを独立したRake applicationへ読み込む。
    def load_are_search_rake_tasks
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)

        gem_root = Gem.loaded_specs.fetch("are_search").full_gem_path
        load File.join(gem_root, "lib", "tasks", "are_search.rake")
    end

    # rake status系テストで使用する2つのIndexTargetを返す。
    def rake_status_index_targets
        [
            DocumentFirst.are_search_index_target(:default),
            DocumentSecond.are_search_index_target(:default),
        ]
    end

    # rake status系テスト用indexを現在定義から作り直す。
    def rebuild_rake_status_indexes
        rake_status_index_targets.each do |index_target|
            result = index_target.are_search_reindex(stage_position: :first)
            expect(result[:result]).to eq(:success)
        end
    end

    # rake status系テストが使用したDB・Elasticsearch状態を削除する。
    def clear_rake_status_state
        DocumentFirst.delete_all
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        AreSearch::SyncLock.delete_all

        target_alias_names = rake_status_index_targets.map(&:are_search_index_alias_name)

        target_alias_names.each do |index_alias_name|
            physical_names = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: index_alias_name,
            ).keys

            current_names = AreSearch::EsAdapter.indices_get_alias(
                index_alias_name: index_alias_name,
            ).keys

            (physical_names + current_names).uniq.each do |physical_index_name|
                delete_index_if_exists(physical_index_name)
            end

            delete_index_if_exists(index_alias_name)
        end

        delete_index_if_exists(orphan_physical_index_name)
    end

    # 指定indexが存在すれば削除する。
    def delete_index_if_exists(index_name)
        AreSearch.client.indices.delete(index: index_name)
    rescue Elastic::Transport::Transport::Errors::NotFound
        nil
    end

    # reindex_allの未接続index検査用物理index名を返す。
    def orphan_physical_index_name
        "#{AreSearch.index_prefix}__orphan__default__2026_08_11_21_40_00_000001"
    end

    # SyncRequestを直接作成してrakeの集計対象にする。
    def create_sync_request(
        sequence,
        model_class: DocumentFirst,
        instance_key: nil,
        last_error: nil,
        processing: false
    )
        index_target = model_class.are_search_index_target(:default)
        now = Time.zone.now

        AreSearch::SyncRequest.create!(
            ar_model_class_name: model_class.name,
            ar_instance_key:     instance_key || sequence.to_s,
            index_alias_name:    index_target.are_search_index_alias_name,
            sync_stage_name:     "default",
            index_target_name:   "default",
            request_sequence:    sequence,
            request_sequence_at: now,
            processing_token:    processing ? "status test" : nil,
            processing_at:       processing ? now : nil,
            last_error:          last_error,
            last_error_at:       last_error.nil? ? nil : now,
        )
    end

    it "acquire_sync_lock_allは全root modelへmanual sync lockを作成し既存sync lockを維持する" do
        document_alias_name = DocumentSecond.are_search_index_target(:default).are_search_index_alias_name
        existing_sync_lock = AreSearch::SyncLock.create!(
            index_alias_name: document_alias_name,
            sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            operation:        "reindex",
            owner_token:      SecureRandom.uuid,
            owner_host:       "test-host",
            owner_pid:        12345,
            started_at:       Time.zone.now,
        )

        output = capture_stdout do
            Rake::Task["are_search:acquire_sync_lock_all"].invoke
        end

        article_alias_name = DocumentFirst.are_search_index_target(:default).are_search_index_alias_name
        article_sync_lock = AreSearch::SyncLock.find_by(index_alias_name: article_alias_name)
        document_sync_lock = AreSearch::SyncLock.find_by(index_alias_name: document_alias_name)

        expect(article_sync_lock.operation).to eq("manual")
        expect(document_sync_lock.id).to eq(existing_sync_lock.id)
        expect(document_sync_lock.operation).to eq("reindex")
        expect(output).to include("acquire_sync_lock_all acquired: #{article_alias_name}")
        expect(output).to include("acquire_sync_lock_all skipped: #{document_alias_name}")
    end

    it "release_sync_lock_allはmanual sync lockだけを削除する" do
        article_alias_name = DocumentFirst.are_search_index_target(:default).are_search_index_alias_name
        document_alias_name = DocumentSecond.are_search_index_target(:default).are_search_index_alias_name

        AreSearch::SyncLock.acquire_index_target_manual!(article_alias_name)
        reindex_sync_lock = AreSearch::SyncLock.create!(
            index_alias_name: document_alias_name,
            sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            operation:        "reindex",
            owner_token:      SecureRandom.uuid,
            owner_host:       "test-host",
            owner_pid:        12345,
            started_at:       Time.zone.now,
        )

        output = capture_stdout do
            Rake::Task["are_search:release_sync_lock_all"].invoke
        end

        expect(AreSearch::SyncLock.find_by(index_alias_name: article_alias_name)).to eq(nil)

        remaining_sync_lock = AreSearch::SyncLock.find_by(index_alias_name: document_alias_name)
        expect(remaining_sync_lock.id).to eq(reindex_sync_lock.id)
        expect(output).to include("release_sync_lock_all released: #{article_alias_name}")
        expect(output).to include("release_sync_lock_all skipped: #{document_alias_name}")
    end

    it "check_sync_request_statusは実DBのsync lock・同期経路別件数・エラー集計を出力する" do
        article_alias_name = DocumentFirst.are_search_index_target(:default).are_search_index_alias_name

        AreSearch::SyncLock.create!(
            index_alias_name: article_alias_name,
            sync_stage_name:  AreSearch::SyncLock.index_target_lock_name,
            operation:        "manual",
            owner_token:      SecureRandom.uuid,
            owner_host:       "test-host",
            owner_pid:        12345,
            started_at:       Time.zone.parse("2026-08-11 10:20:30"),
            message:          "maintenance",
        )

        create_sync_request(1, last_error: "sync locked", processing: true)
        create_sync_request(2, last_error: "sync locked")
        create_sync_request(3)
        create_sync_request(4, model_class: DocumentSecond, last_error: "timeout")

        output = capture_stdout do
            Rake::Task["are_search:check_sync_request_status"].invoke
        end

        expect(output).to include("[AreSearch] sync request status")
        expect(output).to include(article_alias_name)
        expect(output).to include(AreSearch::SyncLock.index_target_lock_name)
        expect(output).to match(/DocumentFirst\s+default\s+default\s+3\s+1\s+2/)
        expect(output).to match(/DocumentSecond\s+default\s+default\s+1\s+0\s+1/)
        expect(output).to match(/DocumentFirst\s+default\s+default\s+sync locked\s+2/)
        expect(output).to match(/DocumentSecond\s+default\s+default\s+timeout\s+1/)
        expect(output).to include("maintenance")
    end

    it "check_sync_request_statusは状態が無い場合に各区分へなしと出力する" do
        AreSearch::SyncLock.delete_all
        AreSearch::SyncRequest.delete_all

        output = capture_stdout do
            Rake::Task["are_search:check_sync_request_status"].invoke
        end

        expect(output.scan(/^なし$/).length).to eq(3)
    end

    it "check_sync_request_statusのエラー内容は件数順の上位20件だけを出力する" do
        21.times do |index|
            create_sync_request(
                index + 1,
                instance_key: index.to_s,
                last_error: "error #{index.to_s.rjust(2, '0')}",
            )
        end

        output = capture_stdout do
            Rake::Task["are_search:check_sync_request_status"].invoke
        end

        expect(output).to include("error 00")
        expect(output).to include("error 19")
        expect(output).not_to include("error 20")
    end

    it "reindex_all_for_es_version_upはsync requestが残っている場合に開始しない" do
        create_sync_request(1)
        $stdin = StringIO.new("y\n")

        expect do
            Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
        end.to raise_error(
            AreSearch::Error,
            /are_search_sync_requests に 1 件残っているため reindex できません/,
        )
    end

    it "reindex_all_for_es_version_upはaliasへ未接続の物理indexがあれば開始しない" do
        AreSearch.client.indices.create(index: orphan_physical_index_name)
        $stdin = StringIO.new("y\n")

        expect do
            Rake::Task["are_search:reindex_all_for_es_version_up"].invoke
        end.to raise_error(
            AreSearch::Error,
            /#{Regexp.escape(orphan_physical_index_name)}/,
        )
    end

    private

    # rake taskの標準出力を文字列として返す。
    def capture_stdout
        original_stdout = $stdout
        output = StringIO.new
        $stdout = output
        yield
        output.string
    ensure
        $stdout = original_stdout
    end
end
