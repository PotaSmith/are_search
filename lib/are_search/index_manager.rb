# frozen_string_literal: true

module AreSearch
    # 物理インデックスのライフサイクル管理。
    #
    # 役割:
    # - 物理インデックス名の生成
    # - alias の作成・切替
    # - 旧方式 index の削除
    # - 古い物理インデックスの clean_up
    # - index 操作用 flock / marker 管理
    #
    # Searchable は参照しない。
    # モデル依存の bulk 投入処理は Searchable 側に置く。
    module IndexManager
        extend self

        PHYSICAL_INDEX_TIMESTAMP_SUFFIX = /_\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}_\d{6}\z/.freeze

        # AreSearch の物理 index 名から alias 名を復元する。
        # 物理 index 名でなければ、そのまま返す。
        def es_alias_name_from_index_name(index_name)
            index_name.to_s.sub(PHYSICAL_INDEX_TIMESTAMP_SUFFIX, "")
        end

        # 互換用。実体は DB 上の index marker の存在判定。
        #
        # flock の状態は見ない。
        def es_index_locked?(es_index_name)
            AreSearch::IndexMarker.marked?(es_index_name)
        end

        def es_index_alias_exists?(es_index_name)
            es_get_alias_physical_names(es_index_name).any?
        end

        # alias の 物理インデックスの一覧。
        def es_get_alias_physical_names(alias_name)
            alias_response = AreSearch.client.indices.get_alias(name: alias_name)
            return [] unless alias_response

            alias_response.keys
        rescue Elastic::Transport::Transport::Errors::NotFound
            []
        end

        def es_index_status(es_index_name)
            current_physical_names = es_get_alias_physical_names(es_index_name)
            physical_names = get_raw_es_index_names("#{es_index_name}_*")
            legacy_index_exists = legacy_index_exists?(es_index_name)

            {
                alias_name:              es_index_name,
                alias_exists:            current_physical_names.any?,
                current_physical_names:  current_physical_names,
                physical_indexes:        build_physical_index_entries(physical_names, current_physical_names),
                newest_physical_name:    newest_physical_index_name(physical_names),
                legacy_index_exists:     legacy_index_exists,
                warnings:                build_index_status_warnings(
                    current_physical_names,
                    physical_names,
                    legacy_index_exists,
                ),
            }
        end

        # alias が指していない古い物理インデックスをすべて削除する。
        def es_clean_up(es_index_name)
            validate_index_operation_enabled!

            locked_message = "[AreSearch] es_clean_up: 別プロセスが実行中のためスキップしました (#{es_index_name})"

            with_index_guard(es_index_name, locked_message, operation: "clean_up") do
                indices   = es_list_indices(es_index_name)
                to_delete = indices.reject { |entry| entry[:current] }

                to_delete.each do |entry|
                    es_delete_index!(entry[:name])
                    AreSearch.logger.info { "[AreSearch] es_clean_up: deleted #{entry[:name]}" }
                end

                true
            end
        rescue AreSearch::IndexLockUnavailable
            # ロック中はfalseを返す
            false
        end

        # 指定した物理インデックスを削除する。
        # ロックによるガードはなし。
        def es_delete_index!(physical_es_index_name)
            validate_index_operation_enabled!

            AreSearch.client.indices.delete(index: physical_es_index_name)
        end

        # 利用側の処理を index 単位の flock と marker でガードする。
        # reindex / clean_up と同じ排他制御を使用し、block の戻り値をそのまま返す。
        # 別処理が flock を取得済み、または marker が存在する場合は false を返す。
        def es_with_index_guard(es_index_name, operation:, &block)
            validate_index_operation_enabled!

            if operation.to_s.empty?
                raise ArgumentError, "operation を指定してください"
            end

            if block.nil?
                raise ArgumentError, "es_with_index_guard には block が必要です"
            end

            operation_name = operation.to_s
            locked_message = "[AreSearch] es_with_index_guard: 別プロセスが実行中のためスキップしました " \
                "(#{es_index_name}, operation=#{operation_name})"

            result = nil

            with_index_guard(es_index_name, locked_message, operation: operation_name) do
                result = block.call
            end

            result
        rescue AreSearch::IndexLockUnavailable
            # ロック中はfalseを返す
            false
        end

        # index 操作の flock と marker を管理する。
        # reindex / 初期 index 作成 / clean up で共通利用する。
        #
        # 流れ:
        # 1. flock を取る
        # 2. marker を作る
        # 3. 新 physical index を作る
        # 4. block 側で bulk 投入
        # 5. 成功したら alias を切り替える
        # 6. marker を消す
        #
        # 正常・例外のどちらでも marker 削除を試みる。
        # marker 削除に到達できない場合、または marker 削除自体が失敗した場合は marker が残る。
        def es_reindex(es_index_name, index_settings, mappings_for_index, &block)
            validate_index_operation_enabled!

            locked_message = "[AreSearch] es_reindex: 別プロセスが実行中のためスキップしました (#{es_index_name})"

            with_index_guard(es_index_name, locked_message, operation: "reindex") do
                physical_es_index_name = gen_physical_es_index_name(es_index_name)

                create_physical_index!(physical_es_index_name, index_settings, mappings_for_index)

                failed_ids = block.call(physical_es_index_name)

                if failed_ids.empty?
                    # 旧方式（alias 名と同名の実体 index）が残っている場合、
                    # alias を作れないため create_physical_index 前で削除する。
                    delete_legacy_index_if_exists!(es_index_name)

                    switch_alias!(es_index_name, physical_es_index_name)
                else
                    report_reindex_failed_ids(es_index_name, physical_es_index_name, failed_ids)
                end

                failed_ids
            end
        rescue AreSearch::IndexLockUnavailable
            # ロック中はfalseを返す
            false
        end

        def validate_index_operation_enabled!
            return if AreSearch.index_operation_enabled

            message = "[AreSearch] index 操作が許可されていません。AreSearch.index_operation_enabled が false になっています。"

            raise AreSearch::IndexOperationViolation, message
        end

        private

        # 物理インデックス名: {alias名}_{マイクロ秒精度タイムスタンプ}
        def gen_physical_es_index_name(es_index_name)
            timestamp = Time.now.strftime("%Y_%m_%d_%H_%M_%S_%6N")

            "#{es_index_name}_#{timestamp}"
        end

        def get_raw_es_index_names(index_pattern)
            AreSearch.client.indices.get(index: index_pattern).keys
        rescue Elastic::Transport::Transport::Errors::NotFound
            []
        end

        def build_physical_index_entries(physical_names, current_physical_names)
            physical_names.sort.map do |physical_name|
                {
                    name:    physical_name,
                    current: current_physical_names.include?(physical_name),
                }
            end
        end

        def newest_physical_index_name(physical_names)
            timestamped_names = physical_names.select { |physical_name| physical_name.to_s.match?(PHYSICAL_INDEX_TIMESTAMP_SUFFIX) }

            return timestamped_names.sort.last if timestamped_names.any?

            physical_names.sort.last
        end

        def legacy_index_exists?(index_name)
            response = AreSearch.client.indices.get(index: index_name)

            response.keys.include?(index_name)
        rescue Elastic::Transport::Transport::Errors::NotFound
            false
        end

        def build_index_status_warnings(current_physical_names, physical_names, legacy_index_exists)
            warnings = []
            newest_physical_name = newest_physical_index_name(physical_names)

            if current_physical_names.empty?
                warnings << "alias missing"
            end

            if physical_names.empty? && legacy_index_exists == false
                warnings << "physical index missing"
            end

            if legacy_index_exists
                warnings << "legacy index exists"
            end

            if newest_physical_name && current_physical_names.any?
                unless current_physical_names.include?(newest_physical_name)
                    warnings << "newest physical index is not current"
                end
            end

            warnings
        end

        # alias に紐づく物理インデックスの一覧。currentでは無いものを含む
        #
        # @return [Array<{ name: String, current: Boolean }>]
        def es_list_indices(es_index_name)
            alias_name        = es_index_name
            current_physicals = es_get_alias_physical_names(alias_name)

            physical_names = get_raw_es_index_names("#{alias_name}_*")

            physical_names.map do |name|
                {
                    name:    name,
                    current: current_physicals.include?(name),
                }
            end
        end

        def delete_legacy_index_if_exists!(alias_name)
            return if AreSearch.client.indices.exists_alias(name: alias_name)
            return unless AreSearch.client.indices.exists(index: alias_name)

            AreSearch.client.indices.delete(index: alias_name)
        rescue Elastic::Transport::Transport::Errors::NotFound
            # exists 後に消えたなら無視
        rescue StandardError => e
            AreSearch.logger.error { "[AreSearch] legacy index delete failed: alias_name=#{alias_name} error=#{e.message}" }
            raise
        end

        def create_physical_index!(physical_es_index_name, index_settings, mappings_for_index)
            AreSearch.client.indices.create(
                index: physical_es_index_name,
                body: {
                    settings: AreSearch.analyzer_settings.merge(index: index_settings),
                    mappings: mappings_for_index,
                },
            )
        end

        def switch_alias!(alias_name, new_physical_es_index_name)
            old_physical_names = es_get_alias_physical_names(alias_name)

            actions = old_physical_names.map do |old_physical_name|
                { remove: { index: old_physical_name, alias: alias_name } }
            end

            actions << { add: { index: new_physical_es_index_name, alias: alias_name } }

            AreSearch.client.indices.update_aliases(body: { actions: actions })
        end

        def report_reindex_failed_ids(es_index_name, physical_es_index_name, failed_ids)
            message = "[AreSearch] es_reindex: bulk 投入に失敗した ID があるため alias を切り替えませんでした "
            message += "alias=#{es_index_name} "
            message += "physical_index=#{physical_es_index_name} "
            message += "failed_ids=#{failed_ids.inspect}"

            AreSearch.logger.error { message }
            puts message
        end

        def with_index_guard(es_index_name, locked_message, operation:, &block)
            lock_path = AreSearch.index_lock_file_path(es_index_name)

            FileUtils.mkdir_p(File.dirname(lock_path))

            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)

                unless locked
                    AreSearch.logger.warn { locked_message }
                    raise AreSearch::IndexLockUnavailable, locked_message
                end

                begin
                    return AreSearch::IndexMarker.with_index_operation_marker!(
                        es_index_name,
                        operation: operation,
                    ) do
                        block.call
                    end
                rescue AreSearch::IndexMarkerUnavailable
                    AreSearch.logger.warn { locked_message }
                    raise AreSearch::IndexLockUnavailable, locked_message
                end
            end
        end
    end
end
