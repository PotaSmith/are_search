# frozen_string_literal: true

module AreSearch
    module IndexManager
        extend self

        # 物理インデックスのライフサイクル管理。
        #
        # 役割:
        # - 物理インデックス名の生成
        # - alias の作成・切替
        # - alias 名と同名の物理 index の削除
        # - 古い物理インデックスの clean_up
        # - index 操作用 flock / marker 管理
        #
        # Searchable は参照しない。
        # モデル依存の bulk 投入処理は Reindexer 側に置く。

        def index_alias_exists?(index_alias_name)
            physical_index_names_by_alias(index_alias_name).any?
        end

        # alias の 物理インデックスの一覧。
        def physical_index_names_by_alias(index_alias_name)
            AreSearch::EsAdapter.indices_get_alias(index_alias_name: index_alias_name).keys
        end

        def index_status(index_alias_name)
            current_physical_names = physical_index_names_by_alias(index_alias_name)
            physical_names = physical_index_names_by_alias_pattern(index_alias_name)
            alias_named_physical_index_exists = alias_named_physical_index_exists?(index_alias_name)

            {
                index_alias_name:        index_alias_name,
                alias_exists:            current_physical_names.any?,
                current_physical_names:  current_physical_names,
                physical_indexes:        build_physical_index_entries(physical_names, current_physical_names),
                newest_physical_name:    newest_physical_index_name(physical_names),
                alias_named_physical_index_exists: alias_named_physical_index_exists,
                warnings:                build_index_status_warnings(
                    current_physical_names,
                    physical_names,
                    alias_named_physical_index_exists,
                ),
            }
        end

        # alias が指していない古い物理インデックスをすべて削除する。
        def index_clean_up(index_alias_name)
            validate_index_operation_enabled!

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
                    delete_physical_index!(physical_name)
                    AreSearch.logger.info { "[AreSearch] index_clean_up: deleted #{physical_name}" }
                    result[:delete_index_names] << physical_name
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
            validate_index_operation_enabled!

            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end

        # 利用側の処理を index 単位の flock と marker でガードする。
        # reindex / clean_up と同じ排他制御を使用し、処理結果を result に設定する。
        # 別処理が flock を取得済み、または marker が存在する場合は block を実行せず、
        # result に未実行理由を設定する。alias が存在しない場合は ArgumentError を送出する。
        def with_index_guard(index_alias_name, result, operation:, &block)
            validate_index_operation_enabled!

            if operation.to_s.empty?
                raise ArgumentError, "operation を指定してください"
            end

            if block.nil?
                raise ArgumentError, "with_index_guard には block が必要です"
            end

            # 利用側の指定誤りで、存在しない alias の guard を開始しない。
            if index_alias_exists?(index_alias_name) == false
                raise ArgumentError, "indexが存在しません #{index_alias_name}"
            end

            operation_name = operation.to_s
            with_index_guard_base(index_alias_name, result, operation: operation_name) do
                block.call

                result[:result] = :success
                result[:stop_phase] = nil
            end
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
            validate_index_operation_enabled!

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

                begin
                    result[:stop_phase] = :delete_alias_duplicate_index
                    # alias 名と同名の物理 index が存在する場合、
                    # alias を作れないため bulk 投入成功後、alias 切り替え前に削除する。
                    delete_alias_named_physical_index_if_exists!(index_alias_name)
                    result[:done_phases] << :delete_alias_duplicate_index
                rescue
                    result[:message] = "alias名と重複する物理インデックスの削除に失敗しました。#{index_alias_name}"
                    return
                end

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

        def validate_index_operation_enabled!
            return if AreSearch.index_operation_enabled

            message = "[AreSearch] index 操作が許可されていません。AreSearch.index_operation_enabled が false になっています。"

            raise AreSearch::IndexOperationViolation, message
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

        def build_physical_index_entries(physical_names, current_physical_names)
            physical_names.sort.map do |physical_name|
                {
                    name:    physical_name,
                    current: current_physical_names.include?(physical_name),
                }
            end
        end

        def newest_physical_index_name(physical_names)
            timestamped_names = physical_names.select { |physical_name| physical_name.to_s.match?(AreSearch::IndexDefinition::PHYSICAL_INDEX_TIMESTAMP_SUFFIX) }

            return timestamped_names.sort.last if timestamped_names.any?

            physical_names.sort.last
        end

        def alias_named_physical_index_exists?(index_alias_name)
            response = AreSearch::EsAdapter.alias_named_physical_index(
                index_alias_name: index_alias_name,
            )

            response.keys.include?(index_alias_name)
        end

        def build_index_status_warnings(current_physical_names, physical_names, alias_named_physical_index_exists)
            warnings = []
            newest_physical_name = newest_physical_index_name(physical_names)

            if current_physical_names.empty?
                warnings << "alias missing"
            end

            if physical_names.empty? && alias_named_physical_index_exists == false
                warnings << "physical index missing"
            end

            if alias_named_physical_index_exists
                warnings << "physical index with alias name exists"
            end

            if newest_physical_name && current_physical_names.any?
                unless current_physical_names.include?(newest_physical_name)
                    warnings << "newest physical index is not current"
                end
            end

            warnings
        end

        def delete_alias_named_physical_index_if_exists!(index_alias_name)
            return if AreSearch::EsAdapter.indices_exists_alias(index_alias_name: index_alias_name)
            return unless AreSearch::EsAdapter.alias_named_physical_index_exists?(
                index_alias_name: index_alias_name,
            )

            AreSearch::EsAdapter.delete_alias_named_physical_index(
                index_alias_name: index_alias_name,
            )
        rescue StandardError => e
            AreSearch.logger.error { "[AreSearch] physical index with alias name delete failed: index_alias_name=#{index_alias_name} error=#{e.message}" }
            raise
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
                    result[:message] = "別プロセスが実行中のためスキップしました"
                    return
                end
                result[:done_phases] << :lock_index

                begin
                    result[:stop_phase] = :create_marker
                    return AreSearch::IndexMarker.with_index_operation_marker!(index_alias_name, operation: operation) do
                        result[:done_phases] << :create_marker
                        block.call
                    end
                rescue AreSearch::IndexMarkerUnavailable
                    result[:message] = "マーカーが作成できませんでした"
                    return
                end
            end
        end
    end
end
