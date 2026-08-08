# frozen_string_literal: true

module AreSearch
    module RakeUtils
        module CheckAllModels
            extend self

            def model_check(klass, errors)
                searchable_from_superclass = klass.superclass&.include?(AreSearch::Searchable)
                declares_mappings_here = klass.singleton_class
                    .public_instance_methods(false)
                    .include?(:are_search_index_mappings)
                declares_ar_table_name_here = klass.singleton_class
                    .public_instance_methods(false)
                    .include?(:are_search_ar_table_name)

                if searchable_from_superclass && declares_mappings_here
                    errors << "#{klass.name}: are_search_index_mappings は Searchable を include した上位クラスで定義してください。"
                end

                if searchable_from_superclass && declares_ar_table_name_here
                    errors << "#{klass.name}: are_search_ar_table_name は Searchable を include した上位クラスで定義してください。"
                end

                return if searchable_from_superclass

                AreSearch::SearchableValidator.validate(klass, errors)
            rescue StandardError => e
                errors << "#{klass.name} のモデル設定検査中に例外が発生しました: #{e.class}: #{e.message}"
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
