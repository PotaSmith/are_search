# frozen_string_literal: true

module AreSearch
    module SearcherUtils
        extend self

        # 検索用汎用 メソッド置き場

        # オプションが未指定の場合だけデフォルト値へ変換する
        def resolve_default_option(value, default_value)
            value.nil? ? default_value : value
        end

        # 検索対象モデルを限定するための Elasticsearch terms 条件を組み立てる。
        # 複数 target が同じモデルを参照する場合はモデル名を重複させない。
        def build_model_filter_clause(index_targets)
            model_class_names = []

            index_targets.each do |index_target|
                model_class_name = index_target.model_class.name
                next if model_class_names.include?(model_class_name)

                model_class_names << model_class_name
            end

            {
                terms: {
                    AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME => model_class_names,
                },
            }
        end

    end
end
