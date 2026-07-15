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

            # Hash または Array<Hash> を、検証済みの条件種別を保持した
            # field / query_type / value 条件へ変換する。
            def normalize_condition_options(condition_opts)
                normalized_conditions = []
                return normalized_conditions if condition_opts.nil?

                if condition_opts.instance_of?(Hash)
                    condition_opts.each do |field, value|
                        value.each do |query_type, query_value|
                            normalized_conditions << {
                                field:      field,
                                query_type: query_type,
                                value:      query_value,
                            }
                        end
                    end

                    return normalized_conditions
                end

                condition_opts.each do |condition_opt|
                    condition_opt.each do |field, value|
                        value.each do |query_type, query_value|
                            normalized_conditions << {
                                field:      field,
                                query_type: query_type,
                                value:      query_value,
                            }
                        end
                    end
                end

                normalized_conditions
            end

            # 共通の field / query_type / value 条件から ES の query 句配列を組み立てる。
            def build_field_clauses(conditions)
                clauses = []

                conditions.each do |condition|
                    clauses << build_field_clause(condition)
                end

                clauses
            end

            # 検証時に確定した query_type に従って、1件の条件を ES query 句へ変換する。
            # value の Ruby 型から条件種別を再推定しない。
            def build_field_clause(condition)
                field = condition[:field]
                query_type = condition[:query_type]
                value = condition[:value]

                if query_type == :term
                    return { term: { field => value } }
                end

                if query_type == :terms
                    return { terms: { field => value } }
                end

                if query_type == :range
                    return { range: { field => value } }
                end

                raise ArgumentError, "未知の条件種別です: #{query_type.inspect}"
            end

            # SearchOptionValidatorで共通形式へ正規化済みのfieldsを、
            # Elasticsearchのcombined_fields用文字列配列へ変換する。
            def build_es_search_fields(fields_opts)
                es_fields = []

                if fields_opts.instance_of?(Array)
                    fields_opts.each do |field|
                        es_fields << build_es_search_field(field, nil)
                    end

                    return es_fields
                elsif fields_opts.instance_of?(Hash)
                    fields_opts.each do |field, boost|
                        es_fields << build_es_search_field(field, boost)
                    end
                else
                    raise ArgumentError, "定義とデータが一致していません: #{fields_opts.inspect}"
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
                bool_clause[:filter] = all_filter_clauses
                bool_clause[:must_not] = must_not_clauses if must_not_clauses.any?

                bool_clause
            end
        end
    end
end
