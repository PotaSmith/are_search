# frozen_string_literal: true

module AreSearch
    class IndexTarget

        attr_reader :model_class, :index_target_name

        class << self

            # 指定モデルが使用する searchable_class_setting を継承元まで辿って返す。
            def searchable_class_setting_for(model_class)
                setting_model_class = searchable_class_setting_model_class(model_class)
                return nil if setting_model_class.nil?

                AreSearch.searchable_class_setting[setting_model_class.name]
            end

            # 指定モデルが使用する searchable_class_setting の定義元クラスを返す。
            def searchable_class_setting_model_class(model_class)
                current_model_class = model_class

                while current_model_class != nil
                    if AreSearch.searchable_class_setting.instance_of?(Hash) &&
                            AreSearch.searchable_class_setting.key?(current_model_class.name)
                        return current_model_class
                    end

                    parent_model_class = current_model_class.superclass
                    break if parent_model_class.nil?
                    break if parent_model_class.include?(AreSearch::Searchable) == false

                    current_model_class = parent_model_class
                end

                nil
            end

            # 指定モデルに定義されたIndexTarget名を設定順で返す。
            def index_target_names(model_class)
                class_setting = searchable_class_setting_for(model_class)
                return [] if class_setting.instance_of?(Hash) == false

                index_target_names = []

                class_setting.each_key do |key|
                    next if key == :_callbacks

                    index_target_names << key
                end

                index_target_names
            end
        end

        # SearchableValidator で検査済みのモデル・index_target_name・設定を保持する。
        def initialize(model_class, index_target_name = :default)
            @model_class = model_class
            @index_target_name = index_target_name
            @ar_table_name = model_class.are_search_ar_table_name

            class_setting = self.class.searchable_class_setting_for(model_class)
            @target_setting = class_setting[index_target_name]
            @callbacks_setting = class_setting[:_callbacks] || {}
        end

        # 同じモデルと index_target_name を持つ IndexTarget を同一targetとして扱う。
        def ==(other)
            return false if other.instance_of?(self.class) == false
            return false if model_class != other.model_class

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

        # index作成時の settings を返す。analysis は AreSearch 側の設定で上書きする。
        def are_search_index_settings
            settings = @target_setting[:settings].dup
            settings[:analysis] = AreSearch.analyzer_settings[:analysis]

            settings
        end

        # mappingsを複製し、properties生成メソッドの結果を設定する。
        # mappings省略時は空Hashを使用する。
        def are_search_index_mappings
            mappings = @target_setting.fetch(:mappings, {}).dup
            properties = model_class.public_send(@target_setting[:properties_method])
            new_properties = {}
            properties.each do |property_key, property_value|
                new_properties[property_key] = property_value
            end
            mappings[:properties] = new_properties

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

        # このIndexTargetに定義された全stageを設定順で返す。
        def are_search_sync_stage_names
            @target_setting[:stages].keys
        end

        # 保存時にSyncRequestを作るstageを設定順で返す。
        def are_search_sync_stage_names_on_enqueue
            sync_stage_names = []

            @target_setting[:stages].each do |sync_stage_name, stage_setting|
                sync_stage_names << sync_stage_name if stage_setting[:enqueue] == true
            end

            sync_stage_names
        end

        # after_commitで同期を開始するstageを設定順で返す。
        def are_search_sync_stage_names_on_after_commit
            sync_stage_names = []

            @target_setting[:stages].each do |sync_stage_name, stage_setting|
                sync_stage_names << sync_stage_name if stage_setting[:after_commit] == true
            end

            sync_stage_names
        end

        # このIndexTargetでレコードをindex対象にするか返す。
        # indexable_method省略時は全レコードを対象にする。
        def are_search_indexable?(record)
            return true unless @target_setting.key?(:indexable_method)

            record.public_send(@target_setting[:indexable_method])
        end

        # 指定stageのindex data生成を設定されたモデルメソッドへ委譲する。
        def are_search_index_data(record, sync_stage_name)
            validate_defined_sync_stage_name!(sync_stage_name)

            data_method = @target_setting[:stages][sync_stage_name][:data_method]
            record.public_send(data_method)
        end

        # 同期前callbackが設定されていればモデルのクラスメソッドへ委譲する。
        def are_search_before_sync_check(ar_instance_key, sync_request)
            method_name = @callbacks_setting[:before_sync_check]
            return true if method_name.nil?

            model_class.public_send(method_name, ar_instance_key, self, sync_request)
        end

        # 同期後callbackが設定されていればモデルのクラスメソッドへ委譲する。
        def are_search_after_sync_callback(record, sync_request)
            method_name = @callbacks_setting[:after_sync_callback]
            return if method_name.nil?

            model_class.public_send(method_name, record, self, sync_request)
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

            if are_search_sync_stage_names.include?(sync_stage_name) == false
                raise ArgumentError, "sync_stage_name が IndexTarget に定義されていません: #{sync_stage_name}"
            end
        end

        # 利用側の _source 設定をコピーし、予約フィールドを includes に追加する。
        # 元の searchable_class_setting は変更しない。
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
    end
end
