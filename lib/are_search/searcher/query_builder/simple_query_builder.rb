# frozen_string_literal: true

module AreSearch
    class SimpleQueryBuilder < QueryBuilderBase
        class << self
            def must_params
                [
                    :fields,
                ].freeze
            end

            def must_not_params
                [
                    :mlt,
                    :raw_body,
                    :queries,
                ].freeze
            end

            # SearchOptionValidatorで正規化済みの検索オプションからqueryを組み立てる。
            def build(index_targets, valid_options)
                query_string   = valid_options.delete(:query_string)
                fields_opts    = valid_options.delete(:fields)
                query_type     = valid_options.delete(:query_type)
                where_opts     = valid_options.delete(:where)
                where_not_opts = valid_options.delete(:where_not)
                where_or_opts  = valid_options.delete(:where_or)

                where_conditions     = normalize_condition_options(where_opts)
                where_not_conditions = normalize_condition_options(where_not_opts)
                where_or_conditions  = normalize_condition_options(where_or_opts)

                filter_clauses   = build_field_clauses(where_conditions)
                must_not_clauses = build_field_clauses(where_not_conditions)
                where_or_clauses = build_field_clauses(where_or_conditions)

                bool_clause = build_bool_base(
                    index_targets,
                    filter_clauses,
                    must_not_clauses,
                    where_or_clauses,
                )

                if query_string.present?
                    bool_clause[:must] = build_text_query_clause(
                        query_string,
                        fields_opts,
                        query_type,
                    )
                end

                { bool: bool_clause }
            end
        end
    end
end
