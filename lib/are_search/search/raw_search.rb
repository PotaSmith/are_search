# frozen_string_literal: true

module AreSearch
    module RawSearch
        extend self
        include SearchBase

        VALID_OPTION_KEYS = [
            :model_includes,
            :model_results_where,
            :page,
            :per_page,
            :build_model_bool,
        ].freeze

        # 利用者が指定した Elasticsearch search body をそのまま検索へ使用する
        def search(index_targets, body, **options)
            raise ArgumentError, "index_targets を指定してください" if index_targets.nil?
            raise ArgumentError, "index_targets は1件以上指定してください" if index_targets.empty?

            models = index_targets_to_models(index_targets)
            models.each { |model| verify_searchable!(model) }

            # --- options 展開 ---
            model_includes_opts      = options[:model_includes]
            model_results_where_opts = options[:model_results_where]
            page_opt                 = options[:page]
            per_page_opt             = options[:per_page]
            build_model_bool_opt     = options[:build_model_bool]

            # --- 全バリデーション ---
            # 未知オプションは、既知オプションの内容検査より先に確定する
            validate_unknown_options!(options, VALID_OPTION_KEYS, caller_name: :raw_search)

            # body は位置引数なので、オプションの内容検査より先に確認する
            validate_raw_search_body!(body)
            validate_build_model_bool_option!(build_model_bool_opt)
            if build_model_bool_opt
                validate_model_bool_body!(body)
            end

            validate_includes_options!(model_includes_opts, models, caller_name: :raw_search)
            validate_results_where_options!(model_results_where_opts, models, caller_name: :raw_search)
            validate_paging_options!(page_opt, per_page_opt, caller_name: :raw_search)

            # --- ここから先はチェックなし ---

            # --- 変換 ---
            model_includes = model_includes_opts
            model_includes = {} if model_includes.nil?

            model_results_filters = model_results_where_opts
            model_results_filters = {} if model_results_filters.nil?

            page     = resolve_default_option(page_opt, 1)
            per_page = resolve_default_option(per_page_opt, 25)

            search_body = body.dup
            if build_model_bool_opt
                search_body = build_raw_search_model_bool(search_body, index_targets)
            end

            search_body.delete(:from)
            search_body.delete("from")
            search_body.delete(:size)
            search_body.delete("size")

            from = (page - 1) * per_page
            size = per_page
            es_from, es_size = resolve_paging_params(index_targets, from, size)

            search_body[:from] = es_from
            search_body[:size] = es_size

            # 未初期化であれば空を返す。もっと早くてもいいが page,per_page はいる
            return empty_search_result(page, per_page) unless check_index_exists?(index_targets)

            # --- 結果復元情報 ---
            result_context = {
                index_to_index_target: build_index_to_index_target(index_targets),
                model_includes:        model_includes,
                model_results_filters: model_results_filters,
                page:                  page,
                per_page:              per_page,
            }

            # --- body実行 ---
            search_index = index_targets.map(&:are_search_es_index_name).join(",")
            execute_and_build_result(search_index, search_body, result_context)
        end

        private

        # build_model_bool は true / false だけを受け付ける。
        def validate_build_model_bool_option!(build_model_bool_opt)
            if build_model_bool_opt.nil? || build_model_bool_opt == true || build_model_bool_opt == false
                return
            end

            raise ArgumentError,
                "raw_search :build_model_bool は true または false で指定してください: " \
                "#{build_model_bool_opt.inspect}"
        end

        # build_model_bool で変更する query.bool.filter の構造を先に確認する。
        def validate_model_bool_body!(body)
            validate_raw_search_key_pair!(body, :query, "body")

            query_key = raw_search_body_key(body, :query)
            if query_key.nil?
                raise ArgumentError,
                    "raw_search :build_model_bool を使用する場合は body に query が必要です"
            end

            query_body = body[query_key]
            if query_body.instance_of?(Hash) == false
                raise ArgumentError,
                    "raw_search :build_model_bool を使用する場合は query を Hash で指定してください: " \
                    "#{query_body.inspect}"
            end

            validate_raw_search_key_pair!(query_body, :bool, "query")

            bool_key = raw_search_body_key(query_body, :bool)
            if bool_key.nil?
                raise ArgumentError,
                    "raw_search :build_model_bool を使用する場合は query.bool が必要です"
            end

            bool_body = query_body[bool_key]
            if bool_body.instance_of?(Hash) == false
                raise ArgumentError,
                    "raw_search :build_model_bool を使用する場合は query.bool を Hash で指定してください: " \
                    "#{bool_body.inspect}"
            end

            validate_raw_search_key_pair!(bool_body, :filter, "query.bool")

            filter_key = raw_search_body_key(bool_body, :filter)
            return if filter_key.nil?

            filter_value = bool_body[filter_key]
            if filter_value.nil? || filter_value.instance_of?(Hash) || filter_value.instance_of?(Array)
                return
            end

            raise ArgumentError,
                "raw_search :build_model_bool を使用する場合は query.bool.filter を " \
                "Hash、Array、nil のいずれかで指定してください: #{filter_value.inspect}"
        end

        # Symbol / String の同名 key が同時にある曖昧な body を拒否する。
        def validate_raw_search_key_pair!(hash, key, path)
            string_key = key.to_s
            if hash.key?(key) && hash.key?(string_key)
                raise ArgumentError,
                    "raw_search #{path} に #{key.inspect} と #{string_key.inspect} を同時に指定できません"
            end
        end

        # 検証済み body から Symbol / String のどちらで指定されたかを返す。
        def raw_search_body_key(hash, key)
            return key if hash.key?(key)

            string_key = key.to_s
            return string_key if hash.key?(string_key)

            nil
        end

        # query.bool.filter を複製し、検索対象モデルの terms 条件を追加する。
        def build_raw_search_model_bool(search_body, index_targets)
            query_key = raw_search_body_key(search_body, :query)
            query_body = search_body[query_key].dup

            bool_key = raw_search_body_key(query_body, :bool)
            bool_body = query_body[bool_key].dup

            filter_key = raw_search_body_key(bool_body, :filter)
            if filter_key.nil?
                filter_key = :filter
                if bool_key.instance_of?(String)
                    filter_key = "filter"
                end
            end

            filter_clauses = []
            existing_filter = bool_body[filter_key]
            if existing_filter.instance_of?(Array)
                filter_clauses = existing_filter.dup
            else
                if existing_filter.nil? == false
                    filter_clauses << existing_filter
                end
            end

            filter_clauses << build_model_filter_clause(index_targets)

            bool_body[filter_key] = filter_clauses
            query_body[bool_key] = bool_body
            search_body[query_key] = query_body

            search_body
        end
    end
end
