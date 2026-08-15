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

        # 対象の Elasticsearch alias が存在するかを返す。
        def are_search_index_alias_exists?
            AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: are_search_index_alias_name,
            )
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
                es_key:           ar_instance_key.to_s,
            )

            if result == AreSearch::EsAdapter.not_success
                raise AreSearch::Error, "Elasticsearch document delete failed"
            end
        end

        private

        # 指定stageがこのIndexTargetに定義されていることを確認する。
        def validate_defined_sync_stage_name!(sync_stage_name)
            AreSearch::IndexDefinition.valid_sync_stage_name!(sync_stage_name)

            sync_stage_names = model_class.are_search_get_all_sync_stage_names(self)
            unless sync_stage_names.include?(sync_stage_name)
                raise ArgumentError, "sync_stage_name が IndexTarget に定義されていません: #{sync_stage_name}"
            end
        end

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
