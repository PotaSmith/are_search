# frozen_string_literal: true

module AreSearch
    module RakeUtils
        extend self

        def model_check(klass, errors)
            puts "are_search_es_data method_defined : #{klass.method_defined?(:are_search_es_data)}"

            unless klass.method_defined?(:are_search_es_data)
                errors << "#{klass.name}: are_search_es_data が実装されていません。"
            end

            puts "are_search_es_mappings respond_to : #{klass.respond_to?(:are_search_es_mappings)}"

            searchable_from_superclass = klass.superclass&.include?(AreSearch::Searchable)
            declares_mappings_here = klass.singleton_class
                .public_instance_methods(false)
                .include?(:are_search_es_mappings)

            if searchable_from_superclass && declares_mappings_here
                errors << "#{klass.name}: are_search_es_mappings は Searchable を include した上位クラスで定義してください。"
            end

            return if searchable_from_superclass

            unless klass.respond_to?(:are_search_es_mappings)
                errors << "#{klass.name}: are_search_es_mappings が実装されていません。"
            end

            if klass.respond_to?(:are_search_es_mappings)
                klass.are_search_validate_model_setting(errors)
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

        # 同じ Elasticsearch index 名が、独立した複数の Searchable 継承系統で
        # 使用されていないかを確認する。
        # STI の親子・兄弟モデルは同じ継承系統として扱い、同名 index を許可する。
        def validate_searchable_index_name_ownership(errors)
            searchable_models = all_searchable_include_models
            root_models = searchable_root_models(searchable_models)

            index_name_owners = {}

            searchable_models.each do |model|
                root_model = nil

                root_models.each do |candidate_model|
                    if model == candidate_model || model < candidate_model
                        root_model = candidate_model
                        break
                    end
                end

                model.are_search_index_targets.each do |index_target|
                    es_index_name = index_target.are_search_es_index_name
                    owner_model = index_name_owners[es_index_name]

                    if owner_model.nil?
                        index_name_owners[es_index_name] = root_model
                        next
                    end

                    next if owner_model == root_model

                    errors << "継承関係のないモデルが同じ index を使用しています: " \
                        "#{es_index_name}: #{owner_model.name}, #{root_model.name}"
                end
            end

            errors.empty?
        end

        # Searchable の全継承系統から、reindex を担当する最上位モデルの
        # index target だけを重複なく返す。
        def searchable_index_target_for_reindex
            # Searchable を直接 include したモデルだけでなく、
            # 継承によって Searchable になった子孫モデルもすべて取得する。
            searchable_models = all_searchable_include_models

            # STI では最上位モデルの relation に子孫モデルも含まれるため、
            # 各 Searchable 継承系統の最上位モデルだけを reindex 対象にする。
            # model < other_model は、直接の親だけでなく祖先全体を判定する。
            reindex_models = searchable_root_models(searchable_models)

            index_targets = []
            es_index_names = []

            # 独立した継承系統の最上位モデル同士で同じ index 名が使われていれば、
            # どちらを reindex 対象にするか決められないためエラーにする。
            reindex_models.each do |model|
                model.are_search_index_targets.each do |index_target|
                    es_index_name = index_target.are_search_es_index_name

                    if es_index_names.include?(es_index_name)
                        raise AreSearch::Error,
                            "[AreSearch] reindex 対象の index が複数の上位モデルで重複しています: #{es_index_name}"
                    end

                    es_index_names << es_index_name
                    index_targets << index_target
                end
            end

            index_targets
        end

        # Searchable モデルを継承系統ごとに整理し、
        # 各系統で最も上位にあるモデルだけを返す。
        def searchable_root_models(searchable_models)
            root_models = []

            searchable_models.each do |model|
                if is_upper_model(model, searchable_models)
                    root_models << model
                end
            end

            root_models
        end

        # modelsの中で最上位のモデルかを判定する
        def is_upper_model(model, models)
            models.each do |other_model|
                next if model == other_model

                # 上位モデルがある
                if model < other_model
                    return false
                end
            end

            return true
        end

        # Searchable を直接 include したモデルだけでなく、
        # 継承によって Searchable になった子孫モデルもすべて取得する。
        def all_searchable_include_models
            Rails.application.eager_load!

            searchable_models = []
            ActiveRecord::Base.descendants.each do |model|
                if model.include?(AreSearch::Searchable)
                    searchable_models << model
                end
            end

            searchable_models
        end
    end
end
