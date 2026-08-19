# frozen_string_literal: true

module AreSearch
    module RakeUtils
        module CheckAllModels
            extend self

            def model_check(klass, errors)
                searchable_from_superclass = klass.superclass&.include?(AreSearch::Searchable)
                declares_ar_table_name_here = klass.singleton_class
                    .public_instance_methods(false)
                    .include?(:are_search_ar_table_name)

                if searchable_from_superclass && declares_ar_table_name_here
                    errors << "#{klass.name}: are_search_ar_table_name は Searchable を include した上位クラスで定義してください。"
                end

                if searchable_from_superclass
                    validate_properties_method_override(klass, errors)
                    validate_sti_setting_methods(klass, errors)
                    return
                end

                class_setting = AreSearch::IndexTarget.searchable_class_setting_for(klass)
                if class_setting.nil?
                    errors << "searchable_class_setting に #{klass.name.inspect} の設定がありません"
                end
            rescue StandardError => e
                errors << "#{klass.name} のモデル設定検査中に例外が発生しました: #{e.class}: #{e.message}"
            end

            # 同じaliasのmappingが子クラスだけ変わらないよう、
            # properties生成メソッドのoverrideを禁止する。
            def validate_properties_method_override(klass, errors)
                class_setting = AreSearch::IndexTarget.searchable_class_setting_for(klass)
                return if class_setting.instance_of?(Hash) == false

                properties_methods = []

                class_setting.each do |index_target_name, target_setting|
                    next if index_target_name == :_callbacks
                    next if target_setting.instance_of?(Hash) == false

                    properties_method = target_setting[:properties_method]
                    next if properties_method.instance_of?(Symbol) == false
                    next if properties_methods.include?(properties_method)

                    properties_methods << properties_method

                    next unless klass.singleton_class.public_instance_methods(false).include?(properties_method)

                    errors << "#{klass.name}: properties_method に指定された #{properties_method} は " \
                        "Searchable を include した上位クラスで定義してください。"
                end
            end

            # STI子クラスで実際に解決される設定メソッドの存在と引数数を確認する。
            # properties_methodはoverride禁止のため、ここではそれ以外だけを対象にする。
            def validate_sti_setting_methods(klass, errors)
                class_setting = AreSearch::IndexTarget.searchable_class_setting_for(klass)
                return if class_setting.instance_of?(Hash) == false

                validate_sti_callback_methods(klass, class_setting[:_callbacks], errors)

                class_setting.each do |index_target_name, target_setting|
                    next if index_target_name == :_callbacks
                    next if target_setting.instance_of?(Hash) == false

                    validate_sti_instance_method(
                        klass,
                        target_setting[:indexable_method],
                        0,
                        "#{index_target_name.inspect}[:indexable_method]",
                        errors,
                    )

                    stages = target_setting[:stages]
                    next if stages.instance_of?(Hash) == false

                    stages.each do |sync_stage_name, stage_setting|
                        next if stage_setting.instance_of?(Hash) == false

                        validate_sti_instance_method(
                            klass,
                            stage_setting[:data_method],
                            0,
                            "#{index_target_name.inspect}[:stages][#{sync_stage_name.inspect}][:data_method]",
                            errors,
                        )
                    end
                end
            end

            # STI子クラスで実際に解決されるsync callbackの存在と引数数を確認する。
            def validate_sti_callback_methods(klass, callbacks, errors)
                return if callbacks.instance_of?(Hash) == false

                callbacks.each do |callback_name, method_name|
                    validate_sti_class_method(
                        klass,
                        method_name,
                        3,
                        "_callbacks[#{callback_name.inspect}]",
                        errors,
                    )
                end
            end

            # STI子クラスで解決されるpublic class methodが存在し、指定引数数か確認する。
            def validate_sti_class_method(klass, method_name, arity, setting_name, errors)
                return if method_name.instance_of?(Symbol) == false

                unless klass.respond_to?(method_name)
                    errors << "#{klass.name}: #{setting_name} に指定されたclass methodがありません: #{klass.name}.#{method_name}"
                    return
                end

                if klass.method(method_name).arity != arity
                    errors << "#{klass.name}.#{method_name} は#{arity}引数で定義してください"
                end
            end

            # STI子クラスで解決されるpublic instance methodが存在し、指定引数数か確認する。
            def validate_sti_instance_method(klass, method_name, arity, setting_name, errors)
                return if method_name.instance_of?(Symbol) == false

                unless klass.public_method_defined?(method_name)
                    errors << "#{klass.name}: #{setting_name} に指定されたinstance methodがありません: #{klass.name}##{method_name}"
                    return
                end

                if klass.instance_method(method_name).arity != arity
                    errors << "#{klass.name}##{method_name} は#{arity}引数で定義してください"
                end
            end

            def check_callback_order(errors)
                # Railsのコールバックチェーンの並び順が想定通りか検証する
                dummy_ar_class = Class.new(ActiveRecord::Base) do
                    self.abstract_class = true
                    after_save :aaa
                    after_save :bbb
                    after_save :ccc
                end
                dummy_ar_sub_class = Class.new(dummy_ar_class) do
                    self.abstract_class = true
                    after_save :ddd
                    after_save :ccc
                end

                callbacks = dummy_ar_class._save_callbacks.select { |cb| cb.kind == :after }.map(&:filter)
                first_pattern = [:ccc, :bbb, :aaa]
                last_pattern  = [:aaa, :bbb, :ccc]
                unless [first_pattern, last_pattern].include?(callbacks)
                    errors << "Railsのコールバック順序がなにやらおかしいです。" \
                              "想定: #{first_pattern.inspect} または #{last_pattern.inspect} 実際: #{callbacks.inspect}"
                end

                sub_callbacks = dummy_ar_sub_class._save_callbacks.select { |cb| cb.kind == :after }.map(&:filter)
                first_pattern_sub = [:ccc, :ddd, :bbb, :aaa]
                last_pattern_sub  = [:aaa, :bbb, :ddd, :ccc]
                unless [first_pattern_sub, last_pattern_sub].include?(sub_callbacks)
                    errors << "Railsのコールバック順序がなにやらおかしいです（サブクラス）。" \
                              "想定: #{first_pattern_sub.inspect} または #{last_pattern_sub.inspect} 実際: #{sub_callbacks.inspect}"
                end
            end

            # 同じ Elasticsearch index_alias_name が、独立した複数の Searchable 継承系統で
            # 使用されていないかを確認する。
            # STI の親子・兄弟モデルは同じ継承系統として扱い、同じ index_alias_name を許可する。
            def validate_searchable_index_alias_name_ownership(errors)
                searchable_models = AreSearch::RakeUtils.all_searchable_include_models
                root_models = AreSearch::RakeUtils.searchable_root_models(searchable_models)

                index_alias_name_owners = {}

                searchable_models.each do |model|
                    root_model = nil

                    root_models.each do |candidate_model|
                        if model == candidate_model || model < candidate_model
                            root_model = candidate_model
                            break
                        end
                    end

                    model.are_search_index_targets.each do |index_target|
                        index_alias_name = index_target.are_search_index_alias_name
                        owner_model = index_alias_name_owners[index_alias_name]

                        if owner_model.nil?
                            index_alias_name_owners[index_alias_name] = root_model
                            next
                        end

                        next if owner_model == root_model

                        errors << "継承関係のないモデルが同じ index を使用しています: " \
                            "#{index_alias_name}: #{owner_model.name}, #{root_model.name}"
                    end
                end

                errors.empty?
            end
        end
    end
end
