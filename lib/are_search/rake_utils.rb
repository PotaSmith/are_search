# frozen_string_literal: true

module AreSearch
    module RakeUtils
        extend self

        def searchable_index_alias_names
            Rails.application.eager_load!

            index_alias_names = []

            ActiveRecord::Base.descendants.select { |klass| klass.include?(AreSearch::Searchable) }.each do |klass|
                klass.are_search_index_targets.each do |index_target|
                    index_alias_name = index_target.are_search_index_alias_name
                    next if index_alias_names.include?(index_alias_name)

                    index_alias_names << index_alias_name
                end
            end

            index_alias_names
        end

        # Searchable モデルを継承系統ごとに整理し、
        # 各系統で最も上位にあるモデルだけを返す。
        def searchable_root_models(searchable_models)
            searchable_models.select do |model|
                is_upper_model(model, searchable_models)
            end
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

            ActiveRecord::Base.descendants.select do |model|
                model.include?(AreSearch::Searchable)
            end
        end
    end
end

require_relative "rake_utils/check_sync_request_status"
require_relative "rake_utils/reindex_all_for_es_version_up"
require_relative "rake_utils/check_all_models"
