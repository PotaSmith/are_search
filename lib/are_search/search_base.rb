
# frozen_string_literal: true

module AreSearch
    module SearchBase
        extend self

        # --- ユーティリティ ---

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

        # 最小の max_result_window を計算
        def resolve_max_result_window(index_targets)
            values = []
            index_targets.each do |index_target|
                value = resolve_model_max_result_window(index_target)
                values << value
            end

            values.min
        end

        # モデルごとの最小の max_result_window を計算
        def resolve_model_max_result_window(index_target)
            model_index_settings = index_target.are_search_es_index_settings || {}
            value = model_index_settings[:max_result_window].to_i
            value = model_index_settings["max_result_window"].to_i if value == 0

            global_index_settings = AreSearch.index_settings || {}
            value = global_index_settings[:max_result_window].to_i if value == 0
            value = global_index_settings["max_result_window"].to_i if value == 0

            value = AreSearch::MAX_RESULT_WINDOW if value == 0

            max_result_window = value

            unless max_result_window > 0
                raise ArgumentError,
                    "#{index_target.model_class.name} #{index_target.target_name} are_search_es_index_settings[:max_result_window] は正の整数で指定してください: #{value.inspect}"
            end

            max_result_window
        end

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

        # --- opts チェック ---

        def index_targets_to_models(index_targets)
            models = []
            index_targets.each do |index_target|
                models << index_target.model_class
            end
            models.uniq
        end

        # model_results_where のキーが models に含まれているかチェックし、ctxに積む
        # arに直接渡す前提のため無加工であること。to_symもしない
        def validate_results_where!(ctx, model_results_where_opts, models, caller_name:)
            return if model_results_where_opts.blank?

            invalid = model_results_where_opts.keys - models
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :model_results_where に models に含まれていないモデルがあります: " \
                    "#{invalid.map(&:name).inspect}"
            end
            ctx[:model_results_filters] = model_results_where_opts
        end

        # model_includes のキーが models に含まれているかチェックし、ctxに積む
        # arに直接渡す前提のため無加工であること。to_symもしない
        def validate_includes!(ctx, model_includes_opts, models, caller_name:)
            return if model_includes_opts.blank?

            invalid = model_includes_opts.keys - models
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :model_includes に models に含まれていないモデルがあります: " \
                    "#{invalid.map(&:name).inspect}"
            end
            ctx[:model_includes] = model_includes_opts
        end

        # --- 実行 ---

        # ES リクエストを実行し、SearchResult を組み立てて返す
        def execute_and_build_result(search_index, search_body, ctx)
            response = AreSearch.client.search(
                index: search_index,
                body:  search_body,
            )

            hits = response.dig("hits", "hits")
            es_total_count = response.dig("hits", "total", "value").to_i

            record_result = build_records(hits, ctx[:index_to_index_target], ctx[:model_results_filters], ctx[:model_includes])

            records = record_result[:records]
            records_with_target_names = record_result[:records_with_target_names]

            total_count = build_display_total_count(es_total_count, hits, records)

            paginated_records = PaginatedCollection.new(
                records,
                current_page:   ctx[:page],
                per_page:       ctx[:per_page],
                total_count:    total_count,
                es_total_count: es_total_count,
            )

            aggs = build_aggs_result(response["aggregations"])
            highlights = build_highlights_hash(hits, ctx[:index_to_index_target])

            SearchResult.new(
                records_with_target_names,
                paginated_records,
                aggs,
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
        def build_records(hits, index_to_index_target, model_results_filters, model_includes)
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
                ids_by_index_target[index_target] << hit["_id"]
            end

            # index_targetごとにDBから取得。複合キー: "#{es_index_name}/#{id}"
            records_by_composite_key = {}
            ids_by_index_target.each do |index_target, ids|
                model = index_target.model_class

                relation = model.where(id: ids)
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

                key = index_target.are_search_es_composite_key(hit["_id"])
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

        # hits から { composite_key => { fragments:, source: } } のハイライトハッシュを組み立てる
        def build_highlights_hash(hits, index_to_index_target)
            result = {}
            hits.each do |hit|
                index_target = index_target_for_hit_index(index_to_index_target, hit["_index"])
                next if index_target.nil?

                key = index_target.are_search_es_composite_key(hit["_id"])
                next if key.nil?

                fragments = (hit["highlight"] || {}).values.flatten(1)
                source    = (hit["_source"] || {}).transform_keys(&:to_sym)
                result[key] = { fragments: fragments, source: source }
            end
            result
        end
    end
end


