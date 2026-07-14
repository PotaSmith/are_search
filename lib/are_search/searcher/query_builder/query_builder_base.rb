# frozen_string_literal: true

module AreSearch
    class QueryBuilderBase
        class << self
            def must_params
                [].freeze
            end

            def must_not_params
                [].freeze
            end

            # SearchOptionValidatorでSymbol化済みのオプションから、
            # 必須・禁止オプションの組み合わせが一致するか確認する。
            def match?(valid_options)
                return false if must_params.nil? || must_not_params.nil?
                return false if must_params.empty? && must_not_params.empty?

                must_valid = must_params.all? do |name|
                    valid_options[name].nil? == false
                end

                must_not_valid = must_not_params.all? do |name|
                    valid_options[name].nil?
                end

                must_valid && must_not_valid
            end

            private

            # Hash または Array<Hash> を共通の field / value / boost 条件へ変換する。
            def normalize_condition_options(condition_opts)
                normalized_conditions = []
                return normalized_conditions if condition_opts.nil?

                if condition_opts.instance_of?(Hash)
                    condition_opts.each do |field, value|
                        value.each do |_query_type, query_value|
                            normalized_conditions << {
                                field: field,
                                value: query_value,
                                boost: nil,
                            }
                        end
                    end

                    return normalized_conditions
                end

                condition_opts.each do |condition_opt|
                    condition_opt.each do |field, value|
                        value.each do |_query_type, query_value|
                            normalized_conditions << {
                                field: field,
                                value: query_value,
                                boost: nil,
                            }
                        end
                    end
                end

                normalized_conditions
            end

            # 共通の field / value / boost 条件から ES の query 句配列を組み立てる。
            def build_field_clauses(conditions)
                clauses = []

                conditions.each do |condition|
                    clauses << build_field_clause(condition)
                end

                clauses
            end

            # 1件の field / value / boost 条件を term / terms / range のいずれかへ変換する。
            def build_field_clause(condition)
                field = condition[:field]
                value = condition[:value]
                boost = condition[:boost]

                if value.instance_of?(Hash)
                    range_value = value.dup
                    range_value[:boost] = boost if boost.nil? == false

                    return { range: { field => range_value } }
                end

                if value.instance_of?(Array)
                    terms_value = { field => value }
                    terms_value[:boost] = boost if boost.nil? == false

                    return { terms: terms_value }
                end

                if boost.nil?
                    return { term: { field => value } }
                end

                { term: { field => { value: value, boost: boost } } }
            end

            # OPTION_DEFINITIONSで許可されたfieldsのArray形式とHash形式を、
            # Elasticsearchのcombined_fields用文字列配列へ変換する。
            #
            # トップレベルfieldsのHash形式はSearchOptionValidatorが
            # field / boost HashのArrayへ正規化しているため、その形式もここで扱う。
            def build_es_search_fields(fields_opts)
                es_fields = []

                if fields_opts.instance_of?(Hash)
                    fields_opts.each do |field, boost|
                        es_fields << build_es_search_field(field, boost)
                    end

                    return es_fields
                end

                fields_opts.each do |field_opts|
                    if field_opts.instance_of?(Hash)
                        field = field_opts[:field]
                        boost = field_opts[:boost]
                        es_fields << build_es_search_field(field, boost)
                        next
                    end

                    es_fields << field_opts.to_s
                end

                es_fields
            end

            # フィールド名と任意のboostからElasticsearchのfields要素を作る。
            def build_es_search_field(field, boost)
                return field.to_s if boost.nil?

                "#{field}^#{boost}"
            end

            # filter / must_not / should 節を持つ bool_clause のベースを組み立てる。
            def build_bool_base(index_targets, filter_clauses, must_not_clauses, where_or_clauses)
                all_filter_clauses = filter_clauses.dup
                model_filter_clause = AreSearch::SearcherUtils.build_model_filter_clause(index_targets)
                all_filter_clauses << model_filter_clause

                if where_or_clauses.any?
                    all_filter_clauses << {
                        bool: {
                            should: where_or_clauses,
                            minimum_should_match: 1,
                        },
                    }
                end

                bool_clause = {}
                bool_clause[:filter] = all_filter_clauses if all_filter_clauses.any?
                bool_clause[:must_not] = must_not_clauses if must_not_clauses.any?

                bool_clause
            end
        end
    end
end
