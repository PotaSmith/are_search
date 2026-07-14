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
                    :mlt_instance,
                    :mlt_index_target,
                    :mlt_params,
                    :raw_body,
                    :queries,
                ].freeze
            end

            # SearchOptionValidatorで正規化済みの検索オプションからqueryを組み立てる。
            def build(index_targets, valid_options)
                query_string   = valid_options.delete(:query_string)
                fields_opts    = valid_options.delete(:fields)
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
                    bool_clause[:must] = build_combined_fields_clause(
                        query_string,
                        fields_opts,
                    )
                end

                { bool: bool_clause }
            end

            private

            # OPTION_DEFINITIONSで検証済みのfieldsからcombined_fields queryを組み立てる。
            def build_combined_fields_clause(query_string, fields_opts)
                {
                    combined_fields: {
                        query:    query_string,
                        fields:   build_es_search_fields(fields_opts),
                        operator: "and",
                    },
                }
            end
        end
    end
end
