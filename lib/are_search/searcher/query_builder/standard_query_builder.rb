# frozen_string_literal: true

module AreSearch
    class StandardQueryBuilder < QueryBuilderBase

        TYPE_COMBINED_FIELDS = :combined_fields
        TYPE_SIMPLE_QUERY_STRING = :simple_query_string

        TYPES = [
            TYPE_COMBINED_FIELDS,
            TYPE_SIMPLE_QUERY_STRING,
        ].freeze

        SIMPLE_QUERY_STRING_FLAGS = "AND|OR|NOT|PHRASE|PRECEDENCE|WHITESPACE|ESCAPE"

        class << self

            # 標準検索の選択に必要なオプションを返す。
            def must_params
                [
                    :queries,
                ].freeze
            end

            # 標準検索と同時に指定できないオプションを返す。
            def must_not_params
                [
                    :raw_body,
                    :mlt,
                ].freeze
            end

            # queries の各要素から標準の bool query を組み立てる。
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

                query_clauses = build_query_clauses(queries_opts)
                if query_clauses.any?
                    bool_clause[:must] = query_clauses
                end

                { bool: bool_clause }
            end

            private

            # 空の検索語を除外し、各要素のquery_typeに対応する全文検索句へ変換する。
            def build_query_clauses(queries_opts)
                clauses = []

                queries_opts.each do |query_opts|
                    query_string = query_opts[:query_string]

                    next if query_string.blank?

                    clauses << build_text_query_clause(
                        query_string,
                        query_opts[:fields],
                        query_opts[:query_type],
                    )
                end

                clauses
            end

            # query_typeに従って、検索語とfieldsから全文検索句を組み立てる。
            # 未指定時は既存動作のcombined_fieldsを使用する。
            def build_text_query_clause(query_string, fields_opts, query_type)
                resolved_query_type = query_type
                if resolved_query_type.nil?
                    resolved_query_type = TYPE_COMBINED_FIELDS
                end

                if resolved_query_type == TYPE_COMBINED_FIELDS
                    return build_combined_fields_clause(
                        query_string,
                        fields_opts,
                    )
                end

                if resolved_query_type == TYPE_SIMPLE_QUERY_STRING
                    return build_simple_query_string_clause(
                        query_string,
                        fields_opts,
                    )
                end

                raise ArgumentError, "未知の query_type です: #{resolved_query_type.inspect}"
            end

            # fieldsを1つの仮想フィールドとして扱うcombined_fields句を組み立てる。
            def build_combined_fields_clause(query_string, fields_opts)
                {
                    combined_fields: {
                        query:    query_string,
                        fields:   build_search_fields(fields_opts),
                        operator: "and",
                    },
                }
            end

            # simple_query_string句を組み立てる。
            # query_stringは変換やescapeを行わず、利用側が指定した検索式をそのまま渡す。
            def build_simple_query_string_clause(query_string, fields_opts)
                {
                    simple_query_string: {
                        query:            query_string,
                        fields:           build_search_fields(fields_opts),
                        default_operator: "and",
                        flags:            SIMPLE_QUERY_STRING_FLAGS,
                    },
                }
            end

            # SearchOptionValidatorで共通形式へ正規化済みのfieldsを、
            # Elasticsearchの全文検索用文字列配列へ変換する。
            def build_search_fields(fields_opts)
                es_fields = []

                if fields_opts.instance_of?(Array)
                    fields_opts.each do |field|
                        es_fields << build_search_field(field, nil)
                    end

                    return es_fields
                elsif fields_opts.instance_of?(Hash)
                    fields_opts.each do |field, boost|
                        es_fields << build_search_field(field, boost)
                    end
                else
                    raise ArgumentError, "定義とデータが一致していません: #{fields_opts.inspect}"
                end

                es_fields
            end

            # フィールド名と任意のboostからElasticsearchのfields要素を作る。
            def build_search_field(field, boost)
                return field.to_s if boost.nil?

                "#{field}^#{boost}"
            end
        end
    end
end
