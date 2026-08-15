# frozen_string_literal: true

module AreSearch
    class IndexTarget

        # alias が指していない古い物理インデックスをすべて削除する（currentのみ残す）。
        def are_search_clean_up
            AreSearch.validate_index_operation_enabled!

            AreSearch::IndexManager.index_clean_up(are_search_index_alias_name)
        end

        # Elasticsearch上に存在しないIndexTargetの空indexを作成する。
        # 既存indexの置き換えには使用せず、aliasが存在する場合は拒否する。
        def are_search_create_index
            AreSearch.validate_index_operation_enabled!

            if are_search_index_alias_exists?
                raise AreSearch::Error, "index は既に存在します: #{are_search_index_alias_name}"
            end

            # 同じ alias を共有する上位モデルの全レコードを欠落させないため、
            # Searchable を継承した子クラスからの reindex を拒否する。
            if model_class.superclass&.include?(AreSearch::Searchable)
                raise AreSearch::Error, "Searchable を継承した子クラスから create_index は実行できません: #{model_class.name}"
            end

            result = {
                result:      :not_success,
                message:     '',
                failed_ids:  [],
                stop_phase:  nil,
                done_phases: [],
            }

            AreSearch::IndexManager.reindex(
                are_search_index_alias_name,
                are_search_index_settings,
                are_search_index_mappings_for_index,
                "create_index",
                result,
            ) do
                true
            end

            result
        end
    end

    # 以下は直接呼ばない

    module IndexManager
        extend self

        # 物理インデックスのライフサイクル管理。
        #
        # Searchable は参照しない。
        # モデル依存の bulk 投入処理は Reindexer 側に置く。

        # alias の 物理インデックスの一覧。
        def physical_index_names_by_alias(index_alias_name)
            AreSearch::EsAdapter.indices_get_alias(index_alias_name: index_alias_name).keys
        end

        # alias が指していない古い物理インデックスをすべて削除する。
        def index_clean_up(index_alias_name)
            result = {
                result: :not_success,
                message: '',
                stop_phase: nil,
                done_phases: [],
                delete_index_names: [],
            }

            with_index_guard_base(index_alias_name, result, operation: "clean_up") do

                result[:stop_phase] = :check_alias
                current_physical_names = physical_index_names_by_alias(index_alias_name)

                if current_physical_names.empty?
                    result[:message] = "alias が存在しないため clean up を実行できません"
                    return result
                end
                result[:done_phases] << :check_alias

                result[:stop_phase] = :delete_indexes
                physical_names = physical_index_names_by_alias_pattern(index_alias_name)
                to_delete = physical_names.reject { |physical_name| current_physical_names.include?(physical_name) }

                to_delete.each do |physical_name|
                    delete_result = delete_physical_index!(physical_name)

                    if delete_result == AreSearch::EsAdapter.success
                        AreSearch.logger.info { "[AreSearch] index_clean_up: deleted #{physical_name}" }
                        result[:delete_index_names] << physical_name
                    end
                end
                result[:done_phases] << :delete_indexes

                result[:result] = :success
                result[:stop_phase] = nil
            end

            result
        end

        # 指定した物理インデックスを削除する。
        # ロックによるガードはなし。
        def delete_physical_index!(physical_index_name)
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end

        # index 操作の flock と sync lock を管理する。
        # reindex / 初期 index 作成 / clean up で共通利用する。
        #
        # 流れ:
        # 1. flock を取る
        # 2. sync lock を取得する
        # 3. 新 physical index を作る
        # 4. block 側で bulk 投入
        # 5. 成功したら alias を切り替える
        # 6. sync lock を解放する
        #
        # 正常・例外のどちらでも sync lock 解放を試みる。
        # sync lock 解放に到達できない場合、または解放自体が失敗した場合は sync lock が残る。
        #
        # {
        #     result: :not_success,
        #     message: e.message,
        #     failed_ids: [],
        #     stop_phase: :lock_index,
        #     done_phases: [],
        # }
        #
        def reindex(index_alias_name, index_settings, mappings_for_index, operation, result, &block)
            if AreSearch::EsAdapter.alias_named_physical_index_exists?(index_alias_name: index_alias_name)
                raise ArgumentError, "エイリアス名と同名の物理インデックスが存在します #{index_alias_name}"
            end

            physical_index_names_by_alias(index_alias_name).each do |physical_index_name|
                AreSearch::IndexDefinition.valid_physical_index_name!(physical_index_name)
            end

            with_index_guard_base(index_alias_name, result, operation: operation) do
                result[:stop_phase] = :create_new_index
                physical_index_name = gen_physical_index_name(index_alias_name)
                create_physical_index!(physical_index_name, index_settings, mappings_for_index)
                result[:done_phases] << :create_new_index

                result[:stop_phase] = :index_to_new_index
                # blockの中では phase は触らない 結果をboolで返すだけ
                if block.call(physical_index_name) == false
                    result[:message] = 'bulk 投入に失敗した ID があるため alias を切り替えませんでした'
                    return
                end
                result[:done_phases] << :index_to_new_index

                result[:stop_phase] = :switch_alias
                # 現行物理インデックスの一覧を取得
                old_physical_names = physical_index_names_by_alias(index_alias_name)

                # 切り替え
                switch_alias_result = AreSearch::EsAdapter.update_alias(
                    old_physical_index_names: old_physical_names,
                    new_physical_index_name:  physical_index_name,
                )
                if switch_alias_result != AreSearch::EsAdapter.success
                    result[:message] = 'インデックスの切り替えに失敗しました。'
                    return
                end
                result[:done_phases] << :switch_alias

                result[:result] = :success
                result[:stop_phase] = nil
            end
        end

        private

        # 物理インデックス名: {alias名}__{マイクロ秒精度タイムスタンプ}
        def gen_physical_index_name(index_alias_name)
            timestamp = Time.zone.now.strftime("%Y_%m_%d_%H_%M_%S_%6N")

            [
                index_alias_name,
                timestamp,
            ].join(AreSearch::IndexDefinition::INDEX_NAME_DELIMITER)
        end

        # 指定 alias 名から生成された timestamp 付き物理 index 名だけを返す。
        # foo と foo__bar のように、指定 alias 名から始まる別 alias の物理 index も除外する。
        # foo__timestamp       → foo      → 残す
        # foo__bar__timestamp  → foo__bar → 除外
        # foo__backup          → nil      → 除外
        def physical_index_names_by_alias_pattern(index_alias_name)
            # 指定 alias 名から始まる index を広めに取得する。
            response = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: index_alias_name,
            )
            raw_index_names = response.keys

            raw_index_names.reject do |raw_index_name|
                # timestamp 付き物理 index 名なら、生成元の alias 名を復元する。
                # timestamp 形式でなければ nil を返す。
                raw_index_alias_name = AreSearch::IndexDefinition.index_alias_name_from_physical_index_name(raw_index_name)

                # 復元できない index と、別 alias から生成された物理 index を除外する。
                raw_index_alias_name != index_alias_name
            end
        end

        def create_physical_index!(physical_index_name, index_settings, mappings_for_index)
            AreSearch::EsAdapter.indices_create(
                physical_index_name: physical_index_name,
                body: {
                    settings: AreSearch.analyzer_settings.merge(index: index_settings),
                    mappings: mappings_for_index,
                },
            )
        end

        def with_index_guard_base(index_alias_name, result, operation:, &block)
            lock_path = AreSearch.index_lock_file_path(index_alias_name)

            FileUtils.mkdir_p(File.dirname(lock_path))

            result[:stop_phase] = :lock_index
            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)

                unless locked
                    result[:message] = "別の処理が実行中のためスキップしました"
                    return
                end
                result[:done_phases] << :lock_index

                begin
                    result[:stop_phase] = :acquire_index_target_sync_lock
                    return AreSearch::SyncLock.with_index_operation!(index_alias_name, operation: operation) do
                        result[:done_phases] << :acquire_index_target_sync_lock
                        block.call
                    end
                rescue AreSearch::SyncLockUnavailable
                    result[:message] = "同期ロックを取得できませんでした"
                    return
                end
            end
        end
    end
end
