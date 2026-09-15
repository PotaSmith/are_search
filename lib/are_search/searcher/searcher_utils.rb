# frozen_string_literal: true

module AreSearch
    module SearcherUtils
        extend self

        # 検索用汎用 メソッド置き場

        # オプションが未指定の場合だけデフォルト値へ変換する
        def resolve_default_option(value, default_value)
            value.nil? ? default_value : value
        end

        # オプションが未指定または0の場合だけデフォルト値へ変換する
        def resolve_page_default_option(value, default_value)
            value.nil? || value.to_i == 0 ? default_value : value
        end

        # 検索対象aliasごとに対応するモデルだけを通す Elasticsearch 条件を組み立てる。
        def build_model_filter_clause(index_targets)
            model_class_names_by_index = {}

            index_targets.each do |index_target|
                index_alias_name = index_target.are_search_index_alias_name.to_s
                model_class_name = index_target.model_class.name
                model_class_names_by_index[index_alias_name] ||= []
                next if model_class_names_by_index[index_alias_name].include?(model_class_name)

                model_class_names_by_index[index_alias_name] << model_class_name
            end

            model_field_name = AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME
            should_clauses = []
            model_class_names_by_index.each do |index_alias_name, model_class_names|
                should_clauses << {
                    bool: {
                        filter: [
                            { term: { _index: index_alias_name } },
                            {
                                terms: {
                                    model_field_name => model_class_names,
                                },
                            },
                        ],
                    },
                }
            end

            {
                bool: {
                    should: should_clauses,
                    minimum_should_match: 1,
                },
            }
        end
    end
end
