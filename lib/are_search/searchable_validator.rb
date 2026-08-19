# frozen_string_literal: true

module AreSearch
    module SearchableValidator
        extend self

        CALLBACK_KEYS = [
            :before_sync_check,
            :after_sync_callback,
        ].freeze

        INDEX_TARGET_SETTING_KEYS = [
            :index_target_name_alias,
            :settings,
            :mappings,
            :properties_method,
            :indexable_method,
            :stages,
        ].freeze

        STAGE_SETTING_KEYS = [
            :data_method,
            :enqueue,
            :after_commit,
        ].freeze

        private_constant :CALLBACK_KEYS
        private_constant :INDEX_TARGET_SETTING_KEYS
        private_constant :STAGE_SETTING_KEYS

        # searchable_class_setting 全体を検査する。
        def validate_searchable_class_setting(setting, errors)
            unless setting.instance_of?(Hash)
                errors << "AreSearch.searchable_class_setting は Hash で指定してください"
                return false
            end

            setting.each do |model_name, class_setting|
                unless model_name.instance_of?(String) && model_name.empty? == false
                    errors << "searchable_class_setting のmodel class名が不正です: #{model_name.inspect}"
                    next
                end

                model_class = model_name.safe_constantize
                unless model_class.instance_of?(Class)
                    errors << "存在しないmodel classです: #{model_name.inspect}"
                    next
                end

                unless model_class.include?(AreSearch::Searchable)
                    errors << "#{model_name} は AreSearch::Searchable を include してください"
                    next
                end

                if model_class.superclass&.include?(AreSearch::Searchable)
                    errors << "#{model_name} の設定はSearchableの上位クラスへ定義してください"
                    next
                end

                unless class_setting.instance_of?(Hash)
                    errors << "searchable_class_setting[#{model_name.inspect}] は Hash で指定してください"
                    next
                end

                validate(model_class, errors)
            end

            errors.empty?
        end

        # 指定Searchableモデルが現在参照する設定を検査し、違反内容をerrorsへ追加する。
        def validate(model_class, errors)
            validate_ar_table_name(model_class, errors)

            class_setting = AreSearch::IndexTarget.searchable_class_setting_for(model_class)
            if class_setting.nil?
                errors << "searchable_class_setting に #{model_class.name.inspect} の設定がありません"
                return false
            end

            unless class_setting.instance_of?(Hash)
                errors << "searchable_class_setting[#{model_class.name.inspect}] は Hash で指定してください"
                return false
            end

            validate_callbacks(model_class, class_setting, errors)
            validate_index_targets(model_class, class_setting, errors)

            errors.empty?
        end

        private

        # Elasticsearch index名に使用するActive Record側の識別名を検査する。
        def validate_ar_table_name(model_class, errors)
            model_name = model_class.name
            ar_table_name = model_class.are_search_ar_table_name

            if AreSearch::IndexDefinition.valid_ar_table_name?(ar_table_name) == false
                errors <<
                    "#{model_name}.are_search_ar_table_name は String で、" \
                    "#{AreSearch::IndexDefinition.definition_name_format_description}: #{ar_table_name.inspect}"
                return false
            end

            true
        end

        # モデル単位のsync callback設定を検査する。
        def validate_callbacks(model_class, class_setting, errors)
            callbacks = class_setting[:_callbacks]
            return true if callbacks.nil?

            path = setting_path(model_class, :_callbacks)

            unless callbacks.instance_of?(Hash)
                errors << "#{path} は Hash で指定してください"
                return false
            end

            callbacks.each do |key, method_name|
                if CALLBACK_KEYS.include?(key) == false
                    errors << "#{path} に不明な設定があります: #{key.inspect}"
                    next
                end

                validate_class_method(model_class, method_name, 3, "#{path}[#{key.inspect}]", errors)
            end

            true
        end

        # IndexTarget設定を設定順に検査する。
        def validate_index_targets(model_class, class_setting, errors)
            index_target_count = 0
            index_target_name_aliases = []

            class_setting.each do |index_target_name, target_setting|
                next if index_target_name == :_callbacks

                index_target_count += 1

                if AreSearch::IndexDefinition.valid_index_target_name?(index_target_name) == false
                    errors <<
                        "#{setting_path(model_class)} の index_target_name は、" \
                        "#{AreSearch::IndexDefinition.definition_name_format_description}: #{index_target_name.inspect}"
                    next
                end

                validate_index_target(model_class, index_target_name, target_setting, errors)

                if target_setting.instance_of?(Hash) && target_setting.key?(:index_target_name_alias)
                    index_target_name_alias = target_setting[:index_target_name_alias]
                    next if AreSearch::IndexDefinition.valid_index_target_name?(index_target_name_alias) == false

                    if index_target_name_aliases.include?(index_target_name_alias)
                        errors << "#{setting_path(model_class)} の index_target_name_alias が重複しています: " \
                            "#{index_target_name_alias.inspect}"
                        next
                    end

                    index_target_name_aliases << index_target_name_alias
                end
            end

            if index_target_count == 0
                errors << "#{setting_path(model_class)} には1件以上のIndexTargetを定義してください"
                return false
            end

            true
        end

        # 1件のIndexTarget設定と参照メソッドを検査する。
        def validate_index_target(model_class, index_target_name, target_setting, errors)
            path = setting_path(model_class, index_target_name)

            unless target_setting.instance_of?(Hash)
                errors << "#{path} は Hash で指定してください"
                return false
            end

            target_setting.each_key do |key|
                if key.instance_of?(Symbol) == false
                    errors << "#{path} のkeyはSymbolで指定してください: #{key.inspect}"
                    next
                end

                if INDEX_TARGET_SETTING_KEYS.include?(key) == false
                    errors << "#{path} に不明な設定があります: #{key.inspect}"
                end
            end

            validate_index_target_name_alias(target_setting, path, errors)
            validate_settings(target_setting, path, errors)
            validate_mappings(target_setting, path, errors)
            validate_properties_method(model_class, target_setting, path, errors)
            validate_indexable_method(model_class, target_setting, path, errors)
            validate_stages(model_class, target_setting, path, errors)

            true
        end

        # IndexTargetの別名を検査する。
        def validate_index_target_name_alias(target_setting, path, errors)
            return true if target_setting.key?(:index_target_name_alias) == false

            index_target_name_alias = target_setting[:index_target_name_alias]
            return true if AreSearch::IndexDefinition.valid_index_target_name?(index_target_name_alias)

            name_format = AreSearch::IndexDefinition.definition_name_format_description
            errors << "#{path}[:index_target_name_alias] は、#{name_format}: #{index_target_name_alias.inspect}"

            false
        end

        # targetのsettingsを検査する。
        # analysisはAreSearch側で設定するため利用側では指定できない。
        def validate_settings(target_setting, path, errors)
            if target_setting.key?(:settings) == false
                errors << "#{path} に :settings がありません"
                return false
            end

            settings = target_setting[:settings]
            if settings.instance_of?(Hash) == false
                errors << "#{path}[:settings] は Hash で指定してください"
                return false
            end

            if symbol_hash_keys?(settings) == false
                errors << "#{path}[:settings] にSymbolではないHash keyがあります"
                return false
            end

            if settings.key?(:analysis)
                errors << "#{path}[:settings] に :analysis は指定できません"
            end

            max_result_window = settings[:max_result_window]
            if max_result_window.instance_of?(Integer) == false || max_result_window <= 0
                errors << "#{path}[:settings][:max_result_window] は正の整数で指定してください"
                return false
            end

            true
        end

        # targetのmappingsを検査する。
        # propertiesはproperties_methodの結果を使用するため利用側では指定できない。
        def validate_mappings(target_setting, path, errors)
            return true if target_setting.key?(:mappings) == false

            mappings = target_setting[:mappings]
            if mappings.instance_of?(Hash) == false
                errors << "#{path}[:mappings] は Hash で指定してください"
                return false
            end

            if symbol_hash_keys?(mappings) == false
                errors << "#{path}[:mappings] にSymbolではないHash keyがあります"
                return false
            end

            if mappings.key?(:properties)
                errors << "#{path}[:mappings] に :properties は指定できません"
            end

            validate_source_settings(mappings, path, errors)

            true
        end

        # mappingsの_source設定を検査する。
        def validate_source_settings(mappings, path, errors)
            return true if mappings.key?(:_source) == false

            source_settings = mappings[:_source]
            if source_settings.instance_of?(Hash) == false
                errors << "#{path}[:mappings][:_source] は Hash で指定してください"
                return false
            end

            if source_settings[:enabled] == false
                errors << "#{path}[:mappings][:_source][:enabled] に false は指定できません"
                return false
            end

            true
        end

        # properties生成メソッドと戻り値を検査する。
        def validate_properties_method(model_class, target_setting, path, errors)
            unless target_setting.key?(:properties_method)
                errors << "#{path} に :properties_method がありません"
                return false
            end

            method_name = target_setting[:properties_method]
            valid_method = validate_class_method(model_class, method_name, 0, "#{path}[:properties_method]", errors)
            return false if valid_method == false

            properties = model_class.public_send(method_name)
            unless properties.instance_of?(Hash)
                errors << "#{model_class.name}.#{method_name} は Hash を返してください"
                return false
            end

            if symbol_hash_keys?(properties) == false
                errors << "#{model_class.name}.#{method_name} の戻り値にSymbolではないHash keyがあります"
                return false
            end

            validate_properties(model_class, method_name, properties, errors)
        end

        # propertiesのfield定義を検査する。
        def validate_properties(model_class, method_name, properties, errors)
            properties.each do |field_name, field_definition|
                if AreSearch::IndexDefinition.valid_index_field_name?(field_name) == false
                    errors <<
                        "#{model_class.name}.#{method_name} の field_name は、" \
                        "#{AreSearch::IndexDefinition.definition_name_format_description}: #{field_name.inspect}"
                    next
                end

                if AreSearch.search_body_policy.invalid_key?(field_name) != false
                    errors <<
                        "#{model_class.name}.#{method_name} に許可されていないfieldがあります: " \
                        "#{field_name}"
                    next
                end

                if field_definition.instance_of?(Hash) == false
                    errors << "#{model_class.name}.#{method_name}[#{field_name.inspect}] はHashが必要です"
                    next
                end

                if field_definition.key?(:type) == false
                    errors << "#{model_class.name}.#{method_name}[#{field_name.inspect}] に :type がありません"
                end
            end

            true
        end

        # IndexTarget単位のindex対象判定メソッドを検査する。
        def validate_indexable_method(model_class, target_setting, path, errors)
            return true if target_setting.key?(:indexable_method) == false

            method_name = target_setting[:indexable_method]
            validate_instance_method(model_class, method_name, 0, "#{path}[:indexable_method]", errors)
        end

        # stage定義とdata生成メソッドを検査する。
        def validate_stages(model_class, target_setting, path, errors)
            unless target_setting.key?(:stages)
                errors << "#{path} に :stages がありません"
                return false
            end

            stages = target_setting[:stages]
            unless stages.instance_of?(Hash)
                errors << "#{path}[:stages] は Hash で指定してください"
                return false
            end

            if stages.empty?
                errors << "#{path}[:stages] には1件以上のstageを定義してください"
                return false
            end

            stages.each do |sync_stage_name, stage_setting|
                validate_stage(model_class, sync_stage_name, stage_setting, path, errors)
            end

            true
        end

        # 1件のstage設定とenqueue・after_commitの関係を検査する。
        def validate_stage(model_class, sync_stage_name, stage_setting, target_path, errors)
            stage_path = "#{target_path}[:stages][#{sync_stage_name.inspect}]"

            if AreSearch::IndexDefinition.valid_sync_stage_name?(sync_stage_name) == false
                errors <<
                    "#{target_path} の sync_stage_name は、" \
                    "#{AreSearch::IndexDefinition.definition_name_format_description}: #{sync_stage_name.inspect}"
                return false
            end

            unless stage_setting.instance_of?(Hash)
                errors << "#{stage_path} は Hash で指定してください"
                return false
            end

            stage_setting.each_key do |key|
                if STAGE_SETTING_KEYS.include?(key) == false
                    errors << "#{stage_path} に不明な設定があります: #{key.inspect}"
                end
            end

            validate_stage_data_method(model_class, stage_setting, stage_path, errors)
            enqueue_valid = validate_boolean_setting(stage_setting, :enqueue, stage_path, errors)
            after_commit_valid = validate_boolean_setting(stage_setting, :after_commit, stage_path, errors)

            if enqueue_valid == true && after_commit_valid == true &&
                    stage_setting[:after_commit] == true && stage_setting[:enqueue] != true
                errors << "#{stage_path} は after_commit: true の場合 enqueue: true にしてください"
            end

            true
        end

        # stageのdata生成メソッドを検査する。
        def validate_stage_data_method(model_class, stage_setting, path, errors)
            if stage_setting.key?(:data_method) == false
                errors << "#{path} に :data_method がありません"
                return false
            end

            validate_instance_method(model_class, stage_setting[:data_method], 0, "#{path}[:data_method]", errors)
        end

        # 必須boolean設定がtrue/falseで指定されているか検査する。
        def validate_boolean_setting(setting, key, path, errors)
            if setting.key?(key) == false
                errors << "#{path} に #{key.inspect} がありません"
                return false
            end

            if setting[key] != true && setting[key] != false
                errors << "#{path}[#{key.inspect}] は true / false で指定してください"
                return false
            end

            true
        end

        # 設定されたpublic class methodの存在と引数数を検査する。
        def validate_class_method(model_class, method_name, arity, path, errors)
            if method_name.instance_of?(Symbol) == false
                errors << "#{path} は Symbol でメソッド名を指定してください"
                return false
            end

            if model_class.respond_to?(method_name) == false
                errors << "#{path} に指定されたclass methodがありません: #{model_class.name}.#{method_name}"
                return false
            end

            if model_class.method(method_name).arity != arity
                errors << "#{model_class.name}.#{method_name} は#{arity}引数で定義してください"
                return false
            end

            true
        end

        # 設定されたpublic instance methodの存在と引数数を検査する。
        def validate_instance_method(model_class, method_name, arity, path, errors)
            if method_name.instance_of?(Symbol) == false
                errors << "#{path} は Symbol でメソッド名を指定してください"
                return false
            end

            if model_class.public_method_defined?(method_name) == false
                errors << "#{path} のinstance methodがありません: #{model_class.name}##{method_name}"
                return false
            end

            if model_class.instance_method(method_name).arity != arity
                errors << "#{model_class.name}##{method_name} は#{arity}引数で定義してください"
                return false
            end

            true
        end

        # searchable_class_setting内のモデル・target位置をエラー表示用文字列で返す。
        def setting_path(model_class, index_target_name = nil)
            path = "AreSearch.searchable_class_setting[#{model_class.name.inspect}]"
            return path if index_target_name.nil?

            "#{path}[#{index_target_name.inspect}]"
        end

        # 定義内に含まれるすべてのHash keyがSymbolか判定する。
        # Array内にHashがある場合も同じ規則を適用する。
        def symbol_hash_keys?(value)
            if value.instance_of?(Hash)
                value.each do |key, child_value|
                    return false if key.instance_of?(Symbol) == false
                    return false if symbol_hash_keys?(child_value) == false
                end
            end

            if value.instance_of?(Array)
                value.each do |child_value|
                    return false if symbol_hash_keys?(child_value) == false
                end
            end

            true
        end
    end
end
