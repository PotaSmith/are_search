# frozen_string_literal: true

module AreSearch
    module SearchBase
        extend self

        # --- ユーティリティ ---

        # Hash / Array 内の key を再帰的に Symbol へ統一する
        def deep_symbolize_opts(opts)
            if opts.instance_of?(Hash)
                return opts.deep_symbolize_keys
            end

            if opts.instance_of?(Array)
                return opts.map do |value|
                    deep_symbolize_opts(value)
                end
            end

            opts
        end

        def index_ready?(index_targets)
            begin
                # 順序大事
                index_marked?(index_targets) == false && check_index_exists?(index_targets) == true
            rescue StandardError
                false
            end
        end

        def check_index_exists?(index_targets)
            index_targets.all? do |index_target|
                AreSearch::IndexManager.es_index_alias_exists?(index_target.are_search_es_index_name)
            end
        end

        def index_marked?(index_targets)
            index_targets.any? do |index_target|
                AreSearch::IndexMarker.marked?(index_target.are_search_es_index_name)
            end
        end

        # 初期化中ようの空のresult
        def empty_search_result(page, per_page)
            paginated = PaginatedCollection.new(
                [],
                current_page:   page,
                per_page:       per_page,
                total_count:    0,
                es_total_count: 0,
            )
            SearchResult.new([], paginated, {}, {})
        end

        # オプションを間違えていないかを確認
        def validate_unknown_options!(options, valid_keys, caller_name:)
            unknown = options.keys.map(&:to_sym) - valid_keys
            return if unknown.empty?

            raise ArgumentError, "#{caller_name} に未知のオプションが指定されています: #{unknown.inspect}"
        end

        # モデルが Searchable を include しているか確認する
        def verify_searchable!(model)
            unless model.include?(AreSearch::Searchable)
                raise ArgumentError, "#{model.name} は AreSearch::Searchable を include していません"
            end
        end

        # models から { es_index_name => index_target } の逆引きマップを組み立てる。
        # ここでは alias 名だけを持つ。
        # 物理 index 名は hit を読む時点で alias 名に戻して解決する。
        def build_index_to_index_target(index_targets)
            result = {}

            index_targets.each do |index_target|
                alias_name = index_target.are_search_es_index_name.to_s
                result[alias_name] = index_target
            end

            result
        end

        # index target のモデル名から Elasticsearch 用の terms 条件を組み立てる
        def build_model_filter_clause(index_targets)
            model_class_names = []

            index_targets.each do |index_target|
                model_class_name = index_target.model_class.name
                if model_class_names.include?(model_class_name) == false
                    model_class_names << model_class_name
                end
            end

            {
                terms: {
                    AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME => model_class_names,
                },
            }
        end

        # 最小の max_result_window を計算
        def resolve_max_result_window(index_targets)
            values = index_targets.map { |index_target| resolve_model_max_result_window(index_target) }

            values.min
        end

        # モデルごとの最小の max_result_window を計算
        def resolve_model_max_result_window(index_target)
            model_index_settings = index_target.are_search_es_index_settings

            model_index_settings[:max_result_window]
        end

        # page / per_page から算出した from / size を max_result_window 内へ収める
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

        # page / per_page が AreSearch 内部で計算可能な正の整数か確認する
        def validate_paging_options!(page_opt, per_page_opt, caller_name:)
            unless page_opt.nil? || page_opt.instance_of?(Integer)
                raise ArgumentError,
                    "#{caller_name} :page は正の整数で指定してください: #{page_opt.inspect}"
            end

            unless per_page_opt.nil? || per_page_opt.instance_of?(Integer)
                raise ArgumentError,
                    "#{caller_name} :per_page は正の整数で指定してください: #{per_page_opt.inspect}"
            end

            if page_opt && page_opt <= 0
                raise ArgumentError,
                    "#{caller_name} :page は正の整数で指定してください: #{page_opt.inspect}"
            end

            if per_page_opt && per_page_opt <= 0
                raise ArgumentError,
                    "#{caller_name} :per_page は正の整数で指定してください: #{per_page_opt.inspect}"
            end
        end

        # オプションが未指定の場合だけデフォルト値へ変換する
        def resolve_default_option(value, default_value)
            value.nil? ? default_value : value
        end

        # --- opts チェック ---

        # index_targets から重複しないモデル一覧を作る
        def index_targets_to_models(index_targets)
            index_targets.map(&:model_class).uniq
        end

        # model_results_where の構造と対象モデルを確認する
        def validate_results_where_options!(model_results_where_opts, models, caller_name:)
            return if model_results_where_opts.nil?

            unless model_results_where_opts.instance_of?(Hash)
                raise ArgumentError,
                    "#{caller_name} :model_results_where は Hash で指定してください: #{model_results_where_opts.inspect}"
            end

            invalid = model_results_where_opts.keys - models
            return if invalid.empty?

            invalid_names = invalid.map(&:name)

            raise ArgumentError,
                "#{caller_name} :model_results_where に models に含まれていないモデルがあります: " \
                "#{invalid_names.inspect}"
        end

        # model_includes の構造と対象モデルを確認する
        def validate_includes_options!(model_includes_opts, models, caller_name:)
            return if model_includes_opts.nil?

            unless model_includes_opts.instance_of?(Hash)
                raise ArgumentError,
                    "#{caller_name} :model_includes は Hash で指定してください: #{model_includes_opts.inspect}"
            end

            invalid = model_includes_opts.keys - models
            return if invalid.empty?

            invalid_names = invalid.map(&:name)

            raise ArgumentError,
                "#{caller_name} :model_includes に models に含まれていないモデルがあります: " \
                "#{invalid_names.inspect}"
        end

        # RawSearch body が利用者定義を保持したまま上書き可能な Hash か確認する
        def validate_raw_search_body!(body)
            return if body.instance_of?(Hash)

            raise ArgumentError,
                "raw_search body は Hash で指定してください: #{body.inspect}"
        end

        # --- 実行 ---

        # ES リクエストを実行し、結果復元情報を使って SearchResult を組み立てる
        def execute_and_build_result(search_index, search_body, result_context)
            response = AreSearch.client.search(
                index: search_index,
                body:  search_body,
            )

            hits = response.dig("hits", "hits")
            es_total_count = response.dig("hits", "total", "value").to_i

            index_to_index_target = result_context[:index_to_index_target]
            model_includes = result_context[:model_includes]
            model_results_filters = result_context[:model_results_filters]
            page = result_context[:page]
            per_page = result_context[:per_page]

            record_result = build_records(
                hits,
                index_to_index_target,
                model_includes,
                model_results_filters,
            )

            records = record_result[:records]
            records_with_target_names = record_result[:records_with_target_names]

            total_count = build_display_total_count(es_total_count, hits, records)

            paginated_records = PaginatedCollection.new(
                records,
                current_page:   page,
                per_page:       per_page,
                total_count:    total_count,
                es_total_count: es_total_count,
            )

            aggs = build_aggs_result(response["aggregations"])

            hit_sources = build_hit_source_hash(hits, index_to_index_target)

            highlights = {}

            # SearchResult の highlight は、hit にフラグメントが返ったかではなく、
            # 検索 body で highlight を要求した場合だけ復元する。
            # RawSearch は body の key を変換しないため、Symbol / String の両方を見る。
            highlight_requested = search_body[:highlight].present?
            if highlight_requested == false
                highlight_requested = search_body["highlight"].present?
            end

            if highlight_requested
                highlights = build_highlights_hash(hits, index_to_index_target)
            end

            SearchResult.new(
                records_with_target_names,
                paginated_records,
                aggs,
                hit_sources,
                highlights,
                raw_response: response,
            )
        end

        private

        def build_aggs_result(aggregations)
            return {} if aggregations.nil?

            result = {}
            aggregations.each do |name, agg|
                buckets = agg["buckets"]
                next if buckets.nil?

                result[name] = buckets.to_h do |bucket|
                    [bucket["key"], bucket["doc_count"]]
                end
            end

            result
        end

        def build_display_total_count(es_total_count, hits, records)
            dropped_count = hits.size - records.size
            dropped_count = 0 if dropped_count < 0

            total_count = es_total_count - dropped_count
            total_count = 0 if total_count < 0

            total_count
        end

        def index_target_for_hit_index(index_to_target, hit_index)
            index_name = hit_index.to_s
            index_target = index_to_target[index_name]
            return index_target unless index_target.nil?

            alias_name = AreSearch::IndexManager.es_alias_name_from_index_name(index_name)
            return nil if alias_name == index_name

            index_to_target[alias_name]
        end

        # ヒット一覧からActiveRecordオブジェクトを復元し、ヒット順に並べて返す
        def build_records(hits, index_to_index_target, model_includes, model_results_filters)
            empty_result = {
                records:                   [],
                records_with_target_names: [],
            }
            return empty_result if hits.empty?

            # index_targetごとにidを集める
            ids_by_index_target = {}
            hits.each do |hit|
                index_target = index_target_for_hit_index(index_to_index_target, hit["_index"])
                if index_target.nil?
                    AreSearch.logger.warn { "[AreSearch] unknown index: #{hit["_index"]}" }
                    next
                end

                ids_by_index_target[index_target] ||= []

                # 検索対象モデルが、保存された Searchable の継承系統に含まれるか確認する
                model_class_names =
                    hit["_source"][AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s]

                if model_class_names.instance_of?(Array)
                    if model_class_names.include?(index_target.model_class.name)
                        ids_by_index_target[index_target] <<
                            hit["_source"][AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s]
                    end
                else
                    if model_class_names == index_target.model_class.name
                        ids_by_index_target[index_target] <<
                            hit["_source"][AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s]
                    end
                end
            end

            # index_targetごとにDBから取得。複合キー: "#{es_index_name}/#{id}"
            records_by_composite_key = {}
            ids_by_index_target.each do |index_target, ids|
                model = index_target.model_class

                relation = model.where(id: ids)
                # DB追加条件で取得対象を確定してから includes を付与する
                relation = relation.where(model_results_filters[model]) if model_results_filters[model].present?

                model_includes_value = model_includes[model]
                relation = relation.includes(model_includes_value) if model_includes_value.present?

                relation.each do |record|
                    key = index_target.are_search_es_composite_key(record.id)
                    records_by_composite_key[key] = record
                end
            end

            records = []
            records_with_target_names = []

            # ヒット順に並び替え
            hits.each do |hit|
                index_target = index_target_for_hit_index(index_to_index_target, hit["_index"])
                next if index_target.nil?

                key = index_target.are_search_es_composite_key(hit["_source"][AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s])
                next if key.nil?

                record = records_by_composite_key[key]
                next if record.nil?

                records << record
                records_with_target_names << [record, index_target.target_name]
            end

            {
                records:                   records,
                records_with_target_names: records_with_target_names,
            }
        end

        # hits から { composite_key => source } の Hash を組み立てる
        def build_hit_source_hash(hits, index_to_index_target)
            result = {}
            hits.each do |hit|
                index_target = index_target_for_hit_index(index_to_index_target, hit["_index"])
                next if index_target.nil?

                key = index_target.are_search_es_composite_key(hit["_source"][AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s])
                next if key.nil?

                source    = (hit["_source"] || {}).transform_keys(&:to_sym)
                result[key] = source
            end
            result
        end

        # hits から { composite_key => fragments } のハイライト Hash を組み立てる
        def build_highlights_hash(hits, index_to_index_target)
            result = {}
            hits.each do |hit|
                index_target = index_target_for_hit_index(index_to_index_target, hit["_index"])
                next if index_target.nil?

                key = index_target.are_search_es_composite_key(hit["_source"][AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s])
                next if key.nil?

                fragments = (hit["highlight"] || {}).values.flatten(1)
                result[key] = fragments
            end
            result
        end
    end
end
