# frozen_string_literal: true

module AreSearch
    module SingleSearch
        extend self
        include SearchBase
        include SearchUtils

        VALID_OPTION_KEYS = [
            :fields,
            :where,
            :where_not,
            :results_where,
            :aggs,
            :includes,
            :page,
            :per_page,
            :sort,
            :highlight,
            :should,
            :minimum_should_match,
        ].freeze

        # 単一モデルを検索する
        #
        # AreSearch::SingleSearch.search(index_target, query, **options)
        # Searchable#are_search_es_search はこのメソッドへのラッパー。
        #
        # @param index_target [Class]                                        Searchable を include したモデル
        # @param query        [String]                                       検索ワード（空なら全件）
        # @option options     [Array<Symbol>, Hash]    :fields               検索対象フィールド (必須) Hashの場合はboost
        # @option options     [Hash]                   :where                絞り込み条件 (値が配列の場合はOR条件)
        # @option options     [Hash]                   :where_not            除外条件 (値が配列の場合はOR条件、must_not に入る)
        # @option options     [Hash]                   :results_where        検索結果をモデル化する際のwhere条件 (例: { status: 'active' })
        # @option options     [Array<Symbol or Hash>]  :aggs                 集計対象フィールド
        # @option options     [Array, Hash]            :includes             ActiveRecord eager loading
        # @option options     [Integer]                :page                 ページ番号 (default: 1)
        # @option options     [Integer]                :per_page             1ページあたりの件数 (default: 25)
        # @option options     [Hash, Array]            :sort                 ソート条件
        # @option options     [Hash]                   :highlight            ハイライト設定
        #                                                                    fields: ハイライト対象フィールド (default: :fields と同じ)
        #                                                                    fragment_size: フラグメント文字数 (default: Elasticsearchのデフォルト = 100)
        # @option options     [Array<Hash>]            :should               should句 各要素は field:, value:, boost:(任意) を持つ
        # @option options     [Object]                 :minimum_should_match should句を最低何件満たすか。指定値は ES にそのまま渡す (default: 1)
        #
        # @return [SearchResult]
        #
        # queryが空の場合は全件が返る。
        #
        def search(index_target, query, **options)
            raise ArgumentError, "index_target を指定してください" if index_target.nil?
            validate_unknown_options!(options, VALID_OPTION_KEYS, caller_name: :are_search_es_search)

            model = index_target.model_class
            verify_searchable!(index_target.model_class)

            index_targets = [index_target]

            # --- options 展開 ---
            fields_opts               = options[:fields]
            where_opts                = options[:where]
            where_not_opts            = options[:where_not]
            results_where_opt         = options[:results_where]
            aggs_opts                 = options[:aggs]
            includes_opts             = options[:includes]
            page_opts                 = [options.fetch(:page, 1).to_i, 1].max
            per_page_opts             = [options.fetch(:per_page, 25).to_i, 1].max
            sort_opts                 = options[:sort]
            highlight_opts            = options[:highlight]
            should_opts               = options[:should]
            minimum_should_match_opts = options[:minimum_should_match]

            # 未初期化であれば空を返す
            return empty_search_result(page_opts, per_page_opts) unless check_index_exists?(index_targets)

            require_fields!(fields_opts, caller_name: :are_search_es_search)

            valid_fields = collect_valid_fields(index_targets)
            normalized_fields = normalize_fields(fields_opts)

            # --- ctx初期化 ---
            ctx = {
                index_targets:         index_targets,
                index_to_index_target: build_index_to_index_target(index_targets),
                page:                  page_opts,
                per_page:              per_page_opts,
                normalized_fields:     [],
                sort:                  {},
                filter_clauses:        [],
                must_not_clauses:      [],
                aggs_fields:           [],
                highlight_fields:      [],
                model_results_filters: {},
                model_includes:        {},
                should_clauses:        [],
                minimum_should_match:  1,
            }

            # --- バリデーション ---
            validate_combined_fields!(ctx, normalized_fields, index_targets, valid_fields, caller_name: :are_search_es_search)
            validate_sort!(ctx, sort_opts, valid_fields, caller_name: :are_search_es_search)
            validate_where!(ctx, where_opts, valid_fields, caller_name: :are_search_es_search)
            validate_where_not!(ctx, where_not_opts, valid_fields, caller_name: :are_search_es_search)
            validate_should!(ctx, should_opts, minimum_should_match_opts, valid_fields, caller_name: :are_search_es_search)
            validate_aggs!(ctx, aggs_opts, valid_fields, caller_name: :are_search_es_search)
            validate_highlight!(ctx, highlight_opts, normalized_fields.map { |f| f[:name] }, valid_fields, caller_name: :are_search_es_search)
            # results_whereとincludesはarに直接渡す前提のため無加工であること。to_symもしない
            validate_single_results_where!(ctx, results_where_opt, model)
            validate_single_includes!(ctx, includes_opts, model)

            # --- body 組み立て ---
            bool_clause = build_bool_base(
                ctx[:filter_clauses],
                ctx[:must_not_clauses],
                ctx[:should_clauses],
                ctx[:minimum_should_match],
            )

            if query.present?
                es_fields = ctx[:normalized_fields].map { |f| f[:boost] ? "#{f[:name]}^#{f[:boost]}" : f[:name].to_s }
                bool_clause[:must] = {
                    combined_fields: {
                        query:    query,
                        fields:   es_fields,
                        operator: "and",
                    },
                }
            end

            from = (page_opts - 1) * per_page_opts
            size = per_page_opts
            es_from, es_size = resolve_paging_params(index_targets, from, size)

            body = {
                track_total_hits: true,
                from:  es_from,
                size:  es_size,
                query: { bool: bool_clause },
            }
            body[:aggs] = build_aggs(ctx[:aggs_fields])                                     if ctx[:aggs_fields].any?
            body[:sort] = ctx[:sort]                                                        if ctx[:sort].present?
            body[:highlight] = build_highlight_body(ctx[:highlight_fields], highlight_opts) if ctx[:highlight_fields].any?

            return body if query.equal?(AreSearch::DumpBody)

            execute_and_build_result(index_target.are_search_es_index_name, body, ctx)
        end

        private

        # arに直接渡す前提のため無加工であること。to_symもしない
        def validate_single_results_where!(ctx, results_where_opt, model)
            return if results_where_opt.blank?

            ctx[:model_results_filters] = { model => results_where_opt }
        end

        # arに直接渡す前提のため無加工であること。to_symもしない
        def validate_single_includes!(ctx, includes_opts, model)
            return if includes_opts.blank?

            ctx[:model_includes] = { model => includes_opts }
        end
    end
end
