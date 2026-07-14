# frozen_string_literal: true

module AreSearch
    class RawBodyBuilder < BodyBuilderBase
        class << self
            # Raw body構築に必要なオプションを返す
            def must_params
                [
                    :raw_body,
                ].freeze
            end

            # Raw body構築で禁止するオプションはQueryBuilder側で判定する
            def must_not_params
                [
                ].freeze
            end

            # 利用者指定bodyを複製し、モデル条件とページングだけを反映する
            def build(index_targets, _query, valid_options)
                raw_body_opt         = valid_options.delete(:raw_body)
                build_model_bool_opt = valid_options.delete(:build_model_bool)
                page_opt             = valid_options.delete(:page)
                per_page_opt         = valid_options.delete(:per_page)

                page = AreSearch::SearcherUtils.resolve_default_option(page_opt, 1)
                per_page = AreSearch::SearcherUtils.resolve_default_option(per_page_opt, 25)

                search_body = raw_body_opt.dup

                if build_model_bool_opt == true
                    search_body = build_raw_search_model_bool(
                        search_body,
                        index_targets,
                    )
                end

                search_body.delete(:from)
                search_body.delete("from")
                search_body.delete(:size)
                search_body.delete("size")

                from = (page - 1) * per_page
                size = per_page
                es_from, es_size = resolve_paging_params(
                    index_targets,
                    from,
                    size,
                )

                search_body[:from] = es_from
                search_body[:size] = es_size

                search_body
            end

            private

            # 検証済みbodyからSymbolまたはStringの実在するkeyを返す
            def raw_body_key(hash, key)
                return key if hash.key?(key)

                string_key = key.to_s
                return string_key if hash.key?(string_key)

                nil
            end

            # query.bool.filterを複製し、検索対象モデルのterms条件を追加する
            def build_raw_search_model_bool(search_body, index_targets)
                query_key = raw_body_key(search_body, :query)
                query_body = search_body[query_key].dup

                bool_key = raw_body_key(query_body, :bool)
                bool_body = query_body[bool_key].dup

                filter_key = raw_body_key(bool_body, :filter)
                if filter_key.nil?
                    filter_key = :filter
                    if bool_key.instance_of?(String)
                        filter_key = "filter"
                    end
                end

                filter_clauses = []
                existing_filter = bool_body[filter_key]

                if existing_filter.instance_of?(Array)
                    existing_filter.each do |filter_clause|
                        filter_clauses << filter_clause
                    end
                else
                    if existing_filter.nil? == false
                        filter_clauses << existing_filter
                    end
                end

                model_filter_clause = AreSearch::SearcherUtils.build_model_filter_clause(
                    index_targets,
                )
                filter_clauses << model_filter_clause

                bool_body[filter_key] = filter_clauses
                query_body[bool_key] = bool_body
                search_body[query_key] = query_body

                search_body
            end

            # pageとper_pageから算出した取得範囲をmax_result_window内へ収める
            def resolve_paging_params(index_targets, from, size)
                max_result_window = resolve_max_result_window(index_targets)

                if from >= max_result_window
                    return [max_result_window, 0]
                end

                if from + size > max_result_window
                    size = max_result_window - from
                end

                size = 0 if size < 0

                [from, size]
            end

            # 検索対象targetの最小max_result_windowを返す
            def resolve_max_result_window(index_targets)
                values = []

                index_targets.each do |index_target|
                    values << resolve_model_max_result_window(index_target)
                end

                values.min
            end

            # 指定targetのmax_result_windowを返す
            def resolve_model_max_result_window(index_target)
                model_index_settings = index_target.are_search_es_index_settings

                model_index_settings[:max_result_window]
            end
        end
    end
end
