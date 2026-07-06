# frozen_string_literal: true

module AreSearch
    module RawSearch
        extend self
        include SearchBase

        VALID_OPTION_KEYS = [
            :model_results_where,
            :model_includes,
            :page,
            :per_page,
        ].freeze

        # 生の検索 body をそのまま Elasticsearch に投げて検索する
        #
        # AreSearch::RawSearch.search(index_targets, body, **options)
        #
        # MultiSearch をベースに、クエリ組み立てを行わず body をそのまま ES へ送る。
        # 検索結果は他の検索メソッドと同じ SearchResult として返す。
        #
        # body 内の from / size は、引数 page / per_page から算出した値で常に上書きする。
        # 利用者が body に書いた from / size（シンボルキー・文字列キーいずれも）は無視される。
        # これは SearchResult（PaginatedCollection）の構築に page / per_page が必須なため。
        #
        # @param index_targets  [Array<Class>]               Searchable を include したモデルの配列
        # @param body           [Hash]                       Elasticsearch に投げる検索 body
        # @option options       [Hash]    :model_results_where  モデルごとのwhere条件 { ModelClass => { 条件 } }
        # @option options       [Hash]    :model_includes       ActiveRecord eager loading { ModelClass => [...] }
        # @option options       [Integer] :page                 ページ番号 (default: 1)
        # @option options       [Integer] :per_page             1ページあたりの件数 (default: 25)
        #
        # @return [SearchResult]
        #
        def search(index_targets, body, **options)
            raise ArgumentError, "index_targets は1件以上指定してください" if index_targets.empty?
            validate_unknown_options!(options, VALID_OPTION_KEYS, caller_name: :raw_search)

            models = index_targets_to_models(index_targets)
            models.each { |model| verify_searchable!(model) }

            # --- options 展開 ---
            model_results_where_opts = options[:model_results_where]
            model_includes_opts      = options[:model_includes]
            page_opts                = [options.fetch(:page, 1).to_i, 1].max
            per_page_opts            = [options.fetch(:per_page, 25).to_i, 1].max

            # 未初期化であれば空を返す
            return empty_search_result(page_opts, per_page_opts) unless check_index_exists?(index_targets)

            # --- ctx初期化 ---
            ctx = {
                index_targets:         index_targets,
                index_to_index_target: build_index_to_index_target(index_targets),
                page:                  page_opts,
                per_page:              per_page_opts,
                model_results_filters: {},
                model_includes:        {},
            }

            # --- バリデーション（整合性チェックのみ。body には手を加えない） ---
            # results_whereとincludesはarに直接渡す前提のため無加工であること。to_symもしない
            validate_results_where!(ctx, model_results_where_opts, models, caller_name: :raw_search)
            validate_includes!(ctx, model_includes_opts, models, caller_name: :raw_search)

            # --- body の from / size を page / per_page で上書き ---
            # 利用者が "from" / "size" のように文字列キーで書いている可能性に備え、
            # まず deep_symbolize_keys でシンボルキーに統一してから上書きする。
            search_body = body.deep_symbolize_keys

            from = (page_opts - 1) * per_page_opts
            size = per_page_opts
            es_from, es_size = resolve_paging_params(index_targets, from, size)

            search_body[:from] = es_from
            search_body[:size] = es_size

            search_index = index_targets.map(&:are_search_es_index_name).join(",")
            execute_and_build_result(search_index, search_body, ctx)
        end
    end
end
