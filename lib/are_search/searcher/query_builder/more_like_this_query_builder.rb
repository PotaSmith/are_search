# frozen_string_literal: true

module AreSearch
    class MoreLikeThisQueryBuilder < QueryBuilderBase
        class << self
            # More Like This の選択に必要なオプションを返す。
            def must_params
                [
                    :mlt,
                ].freeze
            end

            # More Like This と同時に指定できないオプションを返す。
            def must_not_params
                [
                    :raw_body,
                    :queries,
                    :sort,
                ].freeze
            end

            # SearchOptionValidatorで正規化済みの検索オプションからMLT queryを組み立てる。
            def build(index_targets, valid_options)
                mlt_opts       = valid_options.delete(:mlt)
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

                bool_clause[:must] = {
                    more_like_this: build_mlt_clause(mlt_opts),
                }

                {
                    bool: bool_clause,
                }
            end

            private

            # mltをElasticsearchのmore_like_this句へ変換する。
            # instanceとindex_targetはlikeへ変換し、fieldsとその他の検証済みパラメーターを同じ階層へ渡す。
            def build_mlt_clause(mlt_opts)
                instance = mlt_opts[:instance]
                index_target = mlt_opts[:index_target]

                mlt_clause = {
                    fields: mlt_opts[:fields].map(&:to_s),
                    like: [
                        {
                            _index: index_target.are_search_es_index_name,
                            _id:    instance.id.to_s,
                        },
                    ],
                    min_term_freq:   2,
                    min_doc_freq:    5,
                    max_query_terms: 25,
                }

                mlt_opts.each do |key, value|
                    next if key == :instance
                    next if key == :index_target
                    next if key == :fields

                    mlt_clause[key] = value
                end

                mlt_clause
            end
        end
    end
end
