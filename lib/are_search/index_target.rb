# frozen_string_literal: true

module AreSearch
    class IndexTarget

        attr_reader :model_class, :index_target_name

        # SearchableValidator で検査済みのモデルと index_target_name を保持する。
        def initialize(model_class, index_target_name = :default)
            @model_class = model_class
            @index_target_name = index_target_name
            @ar_table_name = model_class.are_search_ar_table_name
        end

        # 同じモデルと index_target_name を持つ IndexTarget を同一targetとして扱う。
        def ==(other)
            return false unless other.instance_of?(self.class)
            return false unless model_class == other.model_class

            index_target_name == other.index_target_name
        end

        # HashのkeyとArray#uniqでも同じ同一target判定を使用する。
        def eql?(other)
            self == other
        end

        # eql?で同一になるIndexTargetが同じHash値を返すようにする。
        def hash
            [
                model_class,
                index_target_name,
            ].hash
        end

        # alias名: {prefix}__{are_search_ar_table_name}__{index_target_name}
        # 検索・index・delete・sync 等、既存の呼び出し元はこの名前を参照する。
        # prefix は config/initializers/are_search.rb で設定。
        def are_search_index_alias_name
            [
                AreSearch.index_prefix,
                @ar_table_name,
                index_target_name,
            ].join(AreSearch::IndexDefinition::INDEX_NAME_DELIMITER)
        end

        # index作成時の index settings
        def are_search_index_settings
            target_mappings[:index_settings]
        end

        # ユーザが定義した are_search_index_mappings
        def are_search_index_mappings
            mappings = {}

            target_mappings.each do |key, value|
                next if key == :index_settings

                if key == :properties
                    new_properties = {}
                    value.each do |property_key, property_value|
                        new_properties[property_key] = property_value
                    end
                    mappings[key] = new_properties
                else
                    mappings[key] = value
                end
            end

            mappings
        end

        # Elasticsearch に渡す mappings を作る。
        # 予約フィールドを properties と _source.includes に追加する。
        def are_search_index_mappings_for_index
            mappings = are_search_index_mappings

            add_reserved_source_includes!(mappings)

            mappings[:properties][AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME] = AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAME_SETTING
            mappings[:properties][AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME] = AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAME_SETTING

            mappings
        end

        # 初期index作成中、reindex 処理中、または異常終了の痕跡があるかを返す。
        def are_search_index_marked?
            AreSearch::IndexMarker.marked?(are_search_index_alias_name)
        end

        # 対象の Elasticsearch alias が存在するかを返す。
        def are_search_index_alias_exists?
            AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: are_search_index_alias_name,
            )
        end

        # alias が指していない古い物理インデックスをすべて削除する（currentのみ残す）。
        def are_search_clean_up
            AreSearch::IndexManager.index_clean_up(are_search_index_alias_name)
        end

        # 利用側の処理を、この index target の flock と marker でガードする。
        # block 内から are_search_index_or_delete! などの低レベル操作を実行する用途を想定する。
        def are_search_with_index_guard(operation:, &block)
            result = {
                result: :not_success,
                message: '',
                stop_phase: nil,
                done_phases: [],
            }

            AreSearch::IndexManager.with_index_guard(
                are_search_index_alias_name,
                result,
                operation: operation,
                &block
            )

            result
        end

        # Elasticsearch上に存在しないIndexTargetの空indexを作成する。
        # 既存indexの置き換えには使用せず、aliasが存在する場合は拒否する。
        def are_search_create_index
            if are_search_index_alias_exists?
                raise AreSearch::Error,
                    "index は既に存在します: #{are_search_index_alias_name}"
            end

            # 同じ alias を共有する上位モデルの全レコードを欠落させないため、
            # Searchable を継承した子クラスからの reindex を拒否する。
            if model_class.superclass&.include?(AreSearch::Searchable)
                raise AreSearch::Error,
                    "Searchable を継承した子クラスから create_index は実行できません: #{model_class.name}"
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

        # 単一の index target を Searcher で検索する。
        # query・fields・query_type は1件の queries へ変換する。
        # 指定された relation は、対象モデルを key にした model_relations へ変換して渡す。
        #
        # @return [SearchResult]
        #
        def are_search_search(query, **options)
            unsupported_options = []
            [:model_relations, :queries].each do |option_name|
                if options.key?(option_name)
                    unsupported_options << option_name
                end
            end
            if unsupported_options.any?
                raise ArgumentError,
                    "are_search_search に未知のオプションが指定されています: #{unsupported_options.inspect}"
            end

            model = model_class
            index_targets = [self]
            relation_opt = options.delete(:relation)
            query_options = {
                query_string: query,
                fields:       options.delete(:fields),
            }
            if options.key?(:query_type)
                query_options[:query_type] = options.delete(:query_type)
            end

            if relation_opt.nil? == false
                options[:model_relations] = {
                    model => relation_opt,
                }
            end

            AreSearch::Searcher.search(index_targets, queries: [query_options], **options)
        end

        # 指定した ar_instance_key のドキュメントをElasticsearchから強制的にdeleteする。
        #
        # sync_request・非同期同期（SyncJob）とは独立した低レベルコマンド。
        # バッチでデータ加工して強制的に更新する、といった用途を想定している。
        # Elasticsearchクライアントの例外はそのまま伝播させる。
        #
        # @param ar_instance_key [Object] 削除対象のid
        # @return [nil] delete成功時と対象不存在時は nil
        def are_search_delete!(ar_instance_key)
            result = AreSearch::EsAdapter.delete(
                index_alias_name: are_search_index_alias_name,
                id:               ar_instance_key.to_s,
            )

            if result == AreSearch::EsAdapter.not_success
                raise AreSearch::Error, "Elasticsearch document delete failed"
            end
        end

        # sync_request 1件分の同期を実行する
        #
        # 先頭で reindex 中かを確認し、reindex 中であれば同期をスキップする。
        # スキップ時は外から見ると成功扱い（例外を出さず正常 return）。
        # SyncRequest は消えず、last_error に reindex 中である旨を記録する。
        # *_try_count は増やさない。
        #
        # reindex 中でない場合は DBから ar_instance_key で再取得し、
        # 存在すればindex、存在しなければdeleteする。
        # 成功時はsync_requestを削除し、失敗時は last_errorを更新する。
        #
        # reraise: true の場合、失敗時に last_error を更新した上で
        # 例外を呼び出し元へ再送出する。SyncJob から retry_on を効かせるために使う。
        # reraise: false（デフォルト）の場合は例外を握りつぶす。rake タスクの
        # run_sync_requests は1件の失敗で全体を止めないため、こちらを使う。
        #
        def are_search_sync(ar_instance_key, sync_stage_name, reraise: false)
            AreSearch::SyncRequest.are_search_find_and_try_sync(
                model_class.name,
                ar_instance_key,
                are_search_index_alias_name,
                sync_stage_name,
                SecureRandom.uuid,
                reraise: reraise,
            )
        end

        private

        # 利用側の _source 設定をコピーし、予約フィールドを includes に追加する。
        # 元の are_search_index_mappings 定義は変更しない。
        def add_reserved_source_includes!(mappings)
            source_settings = {}

            if mappings.key?(:_source)
                source_settings = mappings[:_source].dup
            end

            source_includes = []
            configured_includes = source_settings[:includes]

            if configured_includes.instance_of?(Array)
                configured_includes.each do |field_name|
                    source_includes << field_name
                end
            elsif configured_includes.nil? == false
                source_includes << configured_includes
            end

            AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAMES.each do |reserved_field_name|
                next if source_includes_field?(source_includes, reserved_field_name)

                source_includes << reserved_field_name
            end

            source_settings[:includes] = source_includes
            mappings[:_source] = source_settings
        end

        # Symbol / String の違いを無視して includes 内のフィールド重複を確認する。
        def source_includes_field?(source_includes, field_name)
            source_includes.each do |source_include|
                return true if source_include.to_s == field_name.to_s
            end

            false
        end

        def target_mappings
            model_class.are_search_index_mappings[index_target_name]
        end
    end
end
