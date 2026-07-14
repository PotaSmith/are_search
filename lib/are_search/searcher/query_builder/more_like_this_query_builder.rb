# frozen_string_literal: true

module AreSearch
    class MoreLikeThisQueryBuilder < QueryBuilderBase
        class << self
            # More Like This の選択に必要なオプションを返す。
            def must_params
                [
                    :mlt_instance,
                    :mlt_index_target,
                    :mlt_params,
                ].freeze
            end

            # More Like This と同時に指定できないオプションを返す。
            def must_not_params
                [
                    :raw_body,
                    :query_string,
                    :fields,
                    :queries,
                    :sort,
                ].freeze
            end

            # SearchOptionValidatorで正規化済みの検索オプションからMLT queryを組み立てる。
            def build(index_targets, valid_options)
                mlt_instance     = valid_options.delete(:mlt_instance)
                mlt_index_target = valid_options.delete(:mlt_index_target)
                mlt_params       = valid_options.delete(:mlt_params)
                where_opts       = valid_options.delete(:where)
                where_not_opts   = valid_options.delete(:where_not)
                where_or_opts    = valid_options.delete(:where_or)

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

                mlt_clause = build_mlt_clause(
                    mlt_instance,
                    mlt_index_target,
                    mlt_params,
                )

                bool_clause[:must] = {
                    more_like_this: mlt_clause,
                }

                {
                    bool: bool_clause,
                }
            end

            private

            # mlt_paramsをElasticsearchのmore_like_this句へ変換する。
            # fieldsとlikeはAreSearch側で組み立て、その他の検証済みパラメーターは同じ階層へ渡す。
            def build_mlt_clause(mlt_instance, mlt_index_target, mlt_params)
                mlt_clause = {
                    fields: mlt_params[:fields].map(&:to_s),
                    like: [
                        {
                            _index: mlt_index_target.are_search_es_index_name,
                            _id:    mlt_instance.id.to_s,
                        },
                    ],
                    min_term_freq:   2,
                    min_doc_freq:    5,
                    max_query_terms: 25,
                }

                mlt_params.each do |key, value|
                    next if key == :fields

                    mlt_clause[key] = value
                end

                mlt_clause
            end
        end
    end
end
