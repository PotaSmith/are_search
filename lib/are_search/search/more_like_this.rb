# frozen_string_literal: true

module AreSearch
    module MoreLikeThis
        extend self
        include SearchBase
        include SearchUtils

        VALID_OPTION_KEYS = [
            :fields,
            :where,
            :where_not,
            :where_or,
            :aggs,
            :model_includes,
            :model_results_where,
            :page,
            :per_page,
            :min_term_freq,
            :min_doc_freq,
            :max_query_terms,
            :min_word_length,
            :minimum_should_match,
            :highlight,
        ].freeze

        # 指定したドキュメントを基準に類似ドキュメントを検索する
        def search(index_targets, instance, index_target, **options)
            raise ArgumentError, "index_targets を指定してください" if index_targets.nil?
            raise ArgumentError, "index_targets は1件以上指定してください" if index_targets.empty?

            unless instance.class == index_target.model_class || instance.equal?(AreSearch::DumpBody)
                raise ArgumentError, "instance と index_target のモデルが一致していません"
            end

            models = index_targets_to_models(index_targets)
            models.each do |model|
                verify_searchable!(model)
            end

            validate_mlt_instance!(instance)

            # --- options 展開・key統一 ---
            fields_opts              = deep_symbolize_opts(options[:fields])
            where_opts               = deep_symbolize_opts(options[:where])
            where_not_opts           = deep_symbolize_opts(options[:where_not])
            where_or_opts            = deep_symbolize_opts(options[:where_or])
            aggs_opts                = deep_symbolize_opts(options[:aggs])
            model_includes_opts      = options[:model_includes]
            model_results_where_opts = options[:model_results_where]
            page_opt                 = options[:page]
            per_page_opt             = options[:per_page]
            min_term_freq_opt        = options[:min_term_freq]
            min_doc_freq_opt         = options[:min_doc_freq]
            max_query_terms_opt      = options[:max_query_terms]
            min_word_length_opt      = options[:min_word_length]
            minimum_should_match_opt = options[:minimum_should_match]
            highlight_opts           = deep_symbolize_opts(options[:highlight])

            valid_fields = collect_valid_fields(index_targets)

            # --- 全バリデーション ---
            # 未知オプションは、既知オプションの内容検査より先に確定する
            validate_unknown_options!(options, VALID_OPTION_KEYS, caller_name: :more_like_this)

            validate_mlt_fields_options!(fields_opts, valid_fields, caller_name: :more_like_this)
            validate_condition_options!(where_opts, valid_fields, option_name: :where, caller_name: :more_like_this)
            validate_condition_options!(where_not_opts, valid_fields, option_name: :where_not, caller_name: :more_like_this)
            validate_condition_options!(where_or_opts, valid_fields, option_name: :where_or, caller_name: :more_like_this)
            validate_aggs_options!(aggs_opts, valid_fields, caller_name: :more_like_this)
            validate_includes_options!(model_includes_opts, models, caller_name: :more_like_this)
            validate_results_where_options!(model_results_where_opts, models, caller_name: :more_like_this)
            validate_paging_options!(page_opt, per_page_opt, caller_name: :more_like_this)
            validate_highlight_options!(highlight_opts, valid_fields, caller_name: :more_like_this)

            # --- ここから先はチェックなし ---

            # --- 変換 ---
            mlt_fields           = normalize_mlt_fields(fields_opts)
            where_conditions     = normalize_condition_options(where_opts)
            where_not_conditions = normalize_condition_options(where_not_opts)
            where_or_conditions  = normalize_condition_options(where_or_opts)
            normalized_aggs      = normalize_aggs(aggs_opts)

            model_includes = model_includes_opts
            model_includes = {} if model_includes.nil?

            model_results_filters = model_results_where_opts
            model_results_filters = {} if model_results_filters.nil?

            page            = resolve_default_option(page_opt, 1)
            per_page        = resolve_default_option(per_page_opt, 25)
            min_term_freq   = resolve_default_option(min_term_freq_opt, 2)
            min_doc_freq    = resolve_default_option(min_doc_freq_opt, 5)
            max_query_terms = resolve_default_option(max_query_terms_opt, 25)

            min_word_length      = min_word_length_opt
            minimum_should_match = minimum_should_match_opt
            normalized_highlight = normalize_highlight_options(highlight_opts)

            return empty_search_result(page, per_page) unless check_index_exists?(index_targets)

            # --- body構築 ---
            filter_clauses   = build_field_clauses(where_conditions)
            must_not_clauses = build_field_clauses(where_not_conditions)
            where_or_clauses = build_field_clauses(where_or_conditions)

            bool_clause = build_bool_base(
                index_targets,
                filter_clauses,
                must_not_clauses,
                where_or_clauses,
            )

            mlt_clause = {
                fields:          mlt_fields.map(&:to_s),
                like:            [{ _index: index_target.are_search_es_index_name, _id: instance.id.to_s }],
                min_term_freq:   min_term_freq,
                min_doc_freq:    min_doc_freq,
                max_query_terms: max_query_terms,
            }
            unless min_word_length.nil?
                mlt_clause[:min_word_length] = min_word_length
            end
            if minimum_should_match.nil? == false
                mlt_clause[:minimum_should_match] = minimum_should_match
            end

            bool_clause[:must] = {
                more_like_this: mlt_clause,
            }

            from = (page - 1) * per_page
            size = per_page
            es_from, es_size = resolve_paging_params(index_targets, from, size)

            body = {
                track_total_hits: true,
                from:  es_from,
                size:  es_size,
                query: { bool: bool_clause },
            }
            body[:aggs] = build_aggs(normalized_aggs) if normalized_aggs.any?
            body[:highlight] = build_highlight_body(normalized_highlight) unless normalized_highlight.nil?

            return body if instance.equal?(AreSearch::DumpBody)

            # --- 結果復元情報 ---
            result_context = {
                index_to_index_target: build_index_to_index_target(index_targets),
                model_includes:        model_includes,
                model_results_filters: model_results_filters,
                page:                  page,
                per_page:              per_page,
            }

            search_index = index_targets.map(&:are_search_es_index_name).join(",")
            execute_and_build_result(search_index, body, result_context)
        end

        private

        # instance が Searchable を include したモデルか確認する
        def validate_mlt_instance!(instance)
            return if instance.equal?(AreSearch::DumpBody)

            unless instance.class.include?(AreSearch::Searchable)
                raise ArgumentError,
                    "more_like_this instance (#{instance.class.name}) は AreSearch::Searchable を include していません"
            end
        end
    end
end
