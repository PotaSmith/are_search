# frozen_string_literal: true

module AreSearch
    class ComplexFieldQueryBuilder < QueryBuilderBase
        class << self
            # 複合フィールド検索の選択に必要なオプションを返す。
            def must_params
                [
                    :queries,
                ].freeze
            end

            # 複合フィールド検索と同時に指定できないオプションを返す。
            def must_not_params
                [
                    :raw_body,
                    :query_string,
                    :fields,
                    :mlt_instance,
                    :mlt_index_target,
                    :mlt_params,
                ].freeze
            end

            # フィールド群ごとに異なる検索語を指定したbool queryを組み立てる。
            def build(index_targets, valid_options)
                queries_opts   = valid_options.delete(:queries)
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

                bool_clause[:must] = build_query_clauses(queries_opts)

                { bool: bool_clause }
            end

            private

            # 複合検索条件をcombined_fields queryの配列へ変換する。
            def build_query_clauses(queries_opts)
                clauses = []

                queries_opts.each do |query_opts|
                    clauses << build_combined_fields_clause(query_opts)
                end

                clauses
            end

            # OPTION_DEFINITIONSで検証済みの1件のfieldsからcombined_fields queryを組み立てる。
            def build_combined_fields_clause(query_opts)
                {
                    combined_fields: {
                        query:    query_opts[:query_string],
                        fields:   build_es_search_fields(query_opts[:fields]),
                        operator: "and",
                    },
                }
            end
        end
    end
end
