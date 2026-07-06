
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
            :model_results_where,
            :aggs,
            :model_includes,
            :page,
            :per_page,
            :min_term_freq,
            :min_doc_freq,
            :max_query_terms,
            :min_word_length,
            :highlight,
            :should,
            :minimum_should_match,
        ].freeze

        # 類似ドキュメントを検索する
        #
        # AreSearch::MoreLikeThis.search(index_targets, instance, index_target, **options)
        #
        # @param index_targets   [Array<Class>]                                 Searchable を include したモデルの配列
        # @param instance        [ActiveRecord::Base]                           起点となるレコード。クエリーの変わり
        # @option options        [Array<Symbol>]          :fields               MLT対象フィールド (必須) boost は指定できない。
        # @option options        [Hash]                   :where                絞り込み条件 (値が配列の場合はOR条件、filter に入る)
        # @option options        [Hash]                   :where_not            除外条件 (値が配列の場合はOR条件、must_not に入る)
        # @option options        [Hash]                   :model_results_where  モデルごとのwhere条件 { ModelClass => { 条件 } }
        # @option options        [Array<Symbol or Hash>]  :aggs                 集計対象フィールド
        # @option options        [Hash]                   :model_includes       ActiveRecord eager loading { ModelClass => [...] }
        # @option options        [Integer]                :page                 ページ番号 (default: 1)
        # @option options        [Integer]                :per_page             1ページあたりの件数 (default: 25)
        # @option options        [Integer]                :min_term_freq        MLT: 最低出現頻度 (default: 2)
        # @option options        [Integer]                :min_doc_freq         MLT: 最低ドキュメント頻度 (default: 5)
        # @option options        [Integer]                :max_query_terms      MLT: クエリに使う最大単語数 (default: 25)
        # @option options        [Integer]                :min_word_length      MLT: 最低単語長 (default: nil)
        # @option options        [Hash]                   :highlight            ハイライト設定
        #                                                                       fields: ハイライト対象フィールド (default: :fields と同じ)
        #                                                                       fragment_size: フラグメント文字数 (default: Elasticsearchのデフォルト = 100)
        # @option options        [Array<Hash>]            :should               should句 各要素は field:, value:, boost:(任意) を持つ
        # @option options        [Object]                 :minimum_should_match should句を最低何件満たすか。指定値は ES にそのまま渡す (default: 1)
        #
        # @return [SearchResult]
        #
        def search(index_targets, instance, index_target, **options)
            raise ArgumentError, "index_targets は1件以上指定してください" if index_targets.empty?
            validate_unknown_options!(options, VALID_OPTION_KEYS, caller_name: :more_like_this)

            unless instance.class == index_target.model_class || instance.equal?(AreSearch::DumpBody)
                raise ArgumentError, "instance と index_target のモデルが一致していません"
            end

            models = index_targets_to_models(index_targets)
            models.each { |model| verify_searchable!(model) }

            validate_mlt_instance!(instance)

            # --- options 展開 ---
            fields_opts               = options[:fields]
            where_opts                = options[:where]
            where_not_opts            = options[:where_not]
            model_results_where_opts  = options[:model_results_where]
            aggs_opts                 = options[:aggs]
            model_includes_opts       = options[:model_includes]
            page_opts                 = [options.fetch(:page, 1).to_i, 1].max
            per_page_opts             = [options.fetch(:per_page, 25).to_i, 1].max
            highlight_opts            = options[:highlight]
            min_term_freq_opt         = options[:min_term_freq]
            min_doc_freq_opt          = options[:min_doc_freq]
            max_query_terms_opt       = options[:max_query_terms]
            min_word_length_opt       = options[:min_word_length]
            should_opts               = options[:should]
            minimum_should_match_opts = options[:minimum_should_match]

            # 未初期化であれば空を返す
            return empty_search_result(page_opts, per_page_opts) unless check_index_exists?(index_targets)

            require_fields!(fields_opts, caller_name: :more_like_this)

            valid_fields = collect_valid_fields(index_targets)

            # --- ctx初期化 ---
            ctx = {
                index_targets:         index_targets,
                index_to_index_target: build_index_to_index_target(index_targets),
                page:                  page_opts,
                per_page:              per_page_opts,
                mlt_fields:            [],
                filter_clauses:        [],
                must_not_clauses:      [],
                aggs_fields:           [],
                highlight_fields:      [],
                model_results_filters: {},
                model_includes:        {},
                min_term_freq:         2,
                min_doc_freq:          5,
                max_query_terms:       25,
                min_word_length:       nil,
                should_clauses:        [],
                minimum_should_match:  1,
            }

            # --- バリデーション ---
            validate_no_boost!(fields_opts)
            mlt_fields = validate_mlt_fields!(ctx, fields_opts, valid_fields, index_targets)
            validate_mlt_params!(ctx, min_term_freq_opt, min_doc_freq_opt, max_query_terms_opt, min_word_length_opt)
            validate_where!(ctx, where_opts, valid_fields, caller_name: :more_like_this)
            validate_where_not!(ctx, where_not_opts, valid_fields, caller_name: :more_like_this)
            validate_should!(ctx, should_opts, minimum_should_match_opts, valid_fields, caller_name: :more_like_this)
            validate_aggs!(ctx, aggs_opts, valid_fields, caller_name: :more_like_this)
            validate_highlight!(ctx, highlight_opts, mlt_fields, valid_fields, caller_name: :more_like_this)
            # results_whereとincludesはarに直接渡す前提のため無加工であること。to_symもしない
            validate_results_where!(ctx, model_results_where_opts, models, caller_name: :more_like_this)
            validate_includes!(ctx, model_includes_opts, models, caller_name: :more_like_this)

            # --- body 組み立て ---
            bool_clause = build_bool_base(
                ctx[:filter_clauses],
                ctx[:must_not_clauses],
                ctx[:should_clauses],
                ctx[:minimum_should_match],
            )

            mlt_clause = {
                fields:          ctx[:mlt_fields].map(&:to_s),
                like:            [{ _index: index_target.are_search_es_index_name, _id: instance.id.to_s }],
                min_term_freq:   ctx[:min_term_freq],
                min_doc_freq:    ctx[:min_doc_freq],
                max_query_terms: ctx[:max_query_terms],
            }
            mlt_clause[:min_word_length] = ctx[:min_word_length] if ctx[:min_word_length]

            bool_clause[:must] = { more_like_this: mlt_clause }

            from = (page_opts - 1) * per_page_opts
            size = per_page_opts
            es_from, es_size = resolve_paging_params(index_targets, from, size)

            body = {
                track_total_hits: true,
                from:  es_from,
                size:  es_size,
                query: { bool: bool_clause },
            }
            body[:aggs]      = build_aggs(ctx[:aggs_fields])                                if ctx[:aggs_fields].any?
            body[:highlight] = build_highlight_body(ctx[:highlight_fields], highlight_opts) if ctx[:highlight_fields].any?

            return body if instance.equal?(AreSearch::DumpBody)

            search_index = index_targets.map(&:are_search_es_index_name).join(",")
            execute_and_build_result(search_index, body, ctx)
        end

        private

        # fieldsがArray以外の場合はboost不可としてエラー
        def validate_no_boost!(fields_opts)
            unless fields_opts.instance_of?(Array)
                raise ArgumentError,
                    "more_like_this :fields には Array<Symbol> で指定してください（boost は指定できません）"
            end
        end

        # mlt_fields のチェック（存在確認・型確認）をし、ctxに積む
        def validate_mlt_fields!(ctx, fields_opts, valid_fields, index_targets)
            mlt_fields = fields_opts.map(&:to_sym)

            invalid = mlt_fields - valid_fields
            if invalid.any?
                raise ArgumentError,
                    "more_like_this :fields に未定義のフィールドがあります: #{invalid.inspect}"
            end

            incompatible = []
            mlt_fields.each do |field_name|
                field_defs = []
                index_targets.each do |index_target|
                    defn = index_target.are_search_es_mappings.dig(:properties, field_name)
                    field_defs << defn unless defn.nil?
                end
                compatible = field_defs.any? && field_defs.all? { |field_def| %w[text keyword].include?(field_def[:type].to_s) }
                incompatible << field_name unless compatible
            end
            if incompatible.any?
                raise ArgumentError,
                    "more_like_this :fields には text または keyword 型のフィールドのみ指定できます: " \
                    "#{incompatible.inspect}"
            end

            ctx[:mlt_fields] = mlt_fields
            mlt_fields
        end

        # MLTパラメーターのチェックをし、ctxに積む
        def validate_mlt_params!(ctx, min_term_freq_opt, min_doc_freq_opt, max_query_terms_opt, min_word_length_opt)
            {
                min_term_freq: min_term_freq_opt,
                min_doc_freq: min_doc_freq_opt,
                max_query_terms: max_query_terms_opt,
            }.each do |key, value|
                next if value.nil?
                unless value.instance_of?(Integer) && value > 0
                    raise ArgumentError, "more_like_this :#{key} は正の整数で指定してください"
                end

                ctx[key] = value
            end

            if min_word_length_opt
                unless min_word_length_opt.instance_of?(Integer) && min_word_length_opt > 0
                    raise ArgumentError, "more_like_this :min_word_length は正の整数で指定してください"
                end

                ctx[:min_word_length] = min_word_length_opt
            end
        end

        # instanceがSearchableをincludeしているかチェック
        # DumpBody（デバッグ用センチネル）の場合は検証をスキップして通す
        def validate_mlt_instance!(instance)
            return if instance.equal?(AreSearch::DumpBody)

            unless instance.class.include?(AreSearch::Searchable)
                raise ArgumentError,
                    "more_like_this instance (#{instance.class.name}) は AreSearch::Searchable を include していません"
            end
        end
    end
end


