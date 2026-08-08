# frozen_string_literal: true

module AreSearch
    module SearchableValidator
        extend self

        # Searchable モデルに書かれた静的定義を検査し、errorsへ追加する。
        def validate(model_class, errors)
            validate_ar_table_name(model_class, errors)
            validate_index_data_method(model_class, errors)

            if validate_mappings(model_class, errors)
                validate_sync_stage_settings(model_class, errors)
            end
        end

        private

        # Elasticsearch index 名に使用する Active Record 側の識別名を検査する。
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

        # 同期データを作るインスタンスメソッドが実装されているか検査する。
        def validate_index_data_method(model_class, errors)
            if model_class.method_defined?(:are_search_index_data) == false
                errors << "#{model_class.name}#are_search_index_data が実装されていません"
                return false
            end

            unless model_class.instance_method(:are_search_index_data).arity == 2
                errors << "#{model_class.name}##are_search_index_data は2引数で定義してください"
                return false
            end

            true
        end

        # are_search_index_mappings を上位階層から順に検査する。
        # 最初に定義内のすべての Hash key を検査し、
        # 以降は Symbol key を前提に構造と値を直線的に確認する。
        def validate_mappings(model_class, errors)
            model_name = model_class.name

            if model_class.respond_to?(:are_search_index_mappings) == false
                errors << "#{model_name}.are_search_index_mappings が実装されていません"
                return false
            end

            mappings = model_class.are_search_index_mappings

            if mappings.instance_of?(Hash) == false
                errors << "#{model_name}.are_search_index_mappings は Hash を返してください"
                return false
            end

            if symbol_hash_keys?(mappings) == false
                errors << "#{model_name}.are_search_index_mappings に Symbol ではない key が含まれています"
                return false
            end

            if mappings.empty?
                errors << "#{model_name}.are_search_index_mappings には1件以上の target を定義してください"
                return false
            end

            mappings.each do |index_target_name, mapping|
                if AreSearch::IndexDefinition.valid_index_target_name?(index_target_name) == false
                    errors <<
                        "#{model_name}.are_search_index_mappings の index_target_name は、" \
                        "#{AreSearch::IndexDefinition.definition_name_format_description}: #{index_target_name.inspect}"
                    return false
                end

                if mapping.instance_of?(Hash) == false
                    errors << "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}] は Hash で指定してください"
                    return false
                end

                if validate_index_settings(model_name, index_target_name, mapping, errors) == false
                    return false
                end

                if validate_source_settings(model_name, index_target_name, mapping, errors) == false
                    return false
                end

                if validate_properties(model_name, index_target_name, mapping, errors) == false
                    return false
                end
            end

            true
        end


        # target の index_settings を検査する。
        def validate_index_settings(model_name, index_target_name, mapping, errors)
            if mapping.key?(:index_settings) == false
                errors << "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}] に :index_settings がありません"
                return false
            end

            index_settings = mapping[:index_settings]

            if index_settings.instance_of?(Hash) == false
                errors <<
                    "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                    "[:index_settings] は Hash で指定してください"
                return false
            end

            max_result_window = index_settings[:max_result_window]

            if max_result_window.instance_of?(Integer) == false || max_result_window <= 0
                errors <<
                    "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                    "[:index_settings][:max_result_window] は正の整数で指定してください"
                return false
            end

            true
        end

        # target の _source を検査する。
        def validate_source_settings(model_name, index_target_name, mapping, errors)
            if mapping.key?(:_source) == false
                return true
            end

            source_settings = mapping[:_source]

            if source_settings.instance_of?(Hash) == false
                errors <<
                    "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                    "[:_source] は Hash で指定してください"
                return false
            end

            if source_settings[:enabled] == false
                errors <<
                    "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                    "[:_source][:enabled] に false は指定できません"
                return false
            end

            true
        end

        # target の properties を検査する。
        def validate_properties(model_name, index_target_name, mapping, errors)
            if mapping.key?(:properties) == false
                errors <<
                    "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}] に :properties がありません"
                return false
            end

            properties = mapping[:properties]

            if properties.instance_of?(Hash) == false
                errors <<
                    "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                    "[:properties] は Hash で指定してください"
                return false
            end

            properties.each do |field_name, field_definition|
                if AreSearch::IndexDefinition.valid_index_field_name?(field_name) == false
                    errors <<
                        "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                        "[:properties] の field_name は、#{AreSearch::IndexDefinition.definition_name_format_description}: " \
                        "#{field_name.inspect}"
                    return false
                end

                if AreSearch.search_body_policy.invalid_key?(field_name)
                    errors <<
                        "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                        "[:properties] に検索body policyで許可されていないフィールド名は指定できません: " \
                        "#{field_name}"
                    return false
                end

                if field_definition.instance_of?(Hash) == false
                    errors <<
                        "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                        "[:properties][#{field_name.inspect}] は Hash で指定してください"
                    return false
                end

                if field_definition.key?(:type) == false
                    errors <<
                        "#{model_name}.are_search_index_mappings[#{index_target_name.inspect}]" \
                        "[:properties][#{field_name.inspect}] に :type がありません"
                    return false
                end
            end

            true
        end

        # 3種類のstage設定の構造を確認した後、設定間の包含関係を検査する。
        def validate_sync_stage_settings(model_class, errors)
            model_name = model_class.name

            if model_class.respond_to?(:are_search_all_sync_stage_names) == false
                errors << "#{model_name}.are_search_all_sync_stage_names が実装されていません"
                return false
            end

            # ---------- 全stage定義を確認する ----------

            all_settings = model_class.are_search_all_sync_stage_names

            if valid_sync_stage_map?(all_settings) == false
                errors <<
                    "#{model_name}.are_search_all_sync_stage_names は " \
                    "Symbol key と Array value の Hash を返してください"
                return false
            end

            mappings = model_class.are_search_index_mappings

            if all_settings.keys.length != mappings.keys.length ||
                    all_settings.keys.all? { |index_target_name| mappings.key?(index_target_name) } == false
                errors <<
                    "#{model_name}.are_search_all_sync_stage_names は " \
                    "are_search_index_mappings の全targetを定義してください"
                return false
            end

            all_settings.each do |index_target_name, sync_stage_names|
                if sync_stage_names.empty?
                    errors <<
                        "#{model_name}.are_search_all_sync_stage_names[#{index_target_name.inspect}] は " \
                        "sync_stage_name を1件以上指定してください"
                    return false
                end

                if sync_stage_names.uniq.length != sync_stage_names.length
                    errors <<
                        "#{model_name}.are_search_all_sync_stage_names[#{index_target_name.inspect}] の " \
                        "sync_stage_name は重複できません"
                    return false
                end

                sync_stage_names.each do |sync_stage_name|
                    if AreSearch::IndexDefinition.valid_sync_stage_name?(sync_stage_name) == false
                        errors <<
                            "#{model_name}.are_search_all_sync_stage_names[#{index_target_name.inspect}] の " \
                            "sync_stage_name は、#{AreSearch::IndexDefinition.definition_name_format_description}: #{sync_stage_name.inspect}"
                        return false
                    end
                end
            end

            # ---------- 保存時に要求を作成するstageを確認する ----------

            enqueue_settings = model_class.are_search_sync_stage_names_on_enqueue

            if valid_sync_stage_map?(enqueue_settings) == false
                errors <<
                    "#{model_name}.are_search_sync_stage_names_on_enqueue は " \
                    "Symbol key と Array value の Hash を返してください"
                return false
            end

            if enqueue_settings.equal?(all_settings) == false
                if sync_stage_subset?(enqueue_settings, all_settings) == false
                    errors <<
                        "#{model_name}.are_search_sync_stage_names_on_enqueue は " \
                        "are_search_all_sync_stage_names の部分集合にしてください"
                    return false
                end
            end

            # ---------- after_commitで開始するstageを確認する ----------

            after_commit_settings = model_class.are_search_sync_stage_names_on_after_commit

            if valid_sync_stage_map?(after_commit_settings) == false
                errors <<
                    "#{model_name}.are_search_sync_stage_names_on_after_commit は " \
                    "Symbol key と Array value の Hash を返してください"
                return false
            end

            if after_commit_settings.equal?(enqueue_settings) == false
                if sync_stage_subset?(after_commit_settings, enqueue_settings) == false
                    errors <<
                        "#{model_name}.are_search_sync_stage_names_on_after_commit は " \
                        "are_search_sync_stage_names_on_enqueue の部分集合にしてください"
                    return false
                end
            end

            true
        end

        # stage設定が共通構造を満たすか判定する。
        def valid_sync_stage_map?(stage_settings)
            if stage_settings.instance_of?(Hash) == false
                return false
            end

            stage_settings.each do |index_target_name, sync_stage_names|
                if index_target_name.instance_of?(Symbol) == false
                    return false
                end

                if sync_stage_names.instance_of?(Array) == false
                    return false
                end
            end

            true
        end

        # 子側の全stageが、同じtargetの親側stageに含まれるか判定する。
        def sync_stage_subset?(child_settings, parent_settings)
            child_settings.each do |index_target_name, child_sync_stage_names|
                parent_sync_stage_names = parent_settings[index_target_name]

                if parent_sync_stage_names == nil
                    return false
                end

                child_sync_stage_names.each do |sync_stage_name|
                    if parent_sync_stage_names.include?(sync_stage_name) == false
                        return false
                    end
                end
            end

            true
        end

        # 定義内に含まれるすべてのHash keyがSymbolか判定する。
        # Array内にHashがある場合も同じ規則を適用する。
        def symbol_hash_keys?(value)
            if value.instance_of?(Hash)
                value.each do |key, child_value|
                    if key.instance_of?(Symbol) == false
                        return false
                    end

                    if symbol_hash_keys?(child_value) == false
                        return false
                    end
                end
            end

            if value.instance_of?(Array)
                value.each do |child_value|
                    if symbol_hash_keys?(child_value) == false
                        return false
                    end
                end
            end

            true
        end
    end
end
