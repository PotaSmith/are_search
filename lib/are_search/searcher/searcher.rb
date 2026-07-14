# frozen_string_literal: true

module AreSearch
    module Searcher
        extend self

        # 複数の index target を横断して検索する
        def search(index_targets, **options)
            raise ArgumentError, "index_targets を指定してください" if index_targets.nil?
            raise ArgumentError, "index_targets は1件以上指定してください" if index_targets.empty?

            models = index_targets_to_models(index_targets)
            models.each do |model|
                verify_searchable!(model)
            end

            valid_options = SearchParamValidator.validate(index_targets, models, **options)

            query_options = valid_options.dup
            body_options = valid_options.dup
            query = AreSearch::QueryBuilderSelector.select(valid_options).build(index_targets, query_options)
            body = AreSearch::BodyBuilderSelector.select(valid_options).build(index_targets, query, body_options)

            # ここで使うオプションを取る
            search_options = valid_options.dup

            model_includes_opts      = search_options.delete(:model_includes)
            model_results_where_opts = search_options.delete(:model_results_where)
            page_opts                = search_options.delete(:page)
            per_page_opts            = search_options.delete(:per_page)
            dump_body_opts           = search_options.delete(:dump_body)

            # 未使用のオプションがあるか
            left_options = query_options.keys & body_options.keys & search_options.keys
            if left_options.any?
                raise ArgumentError, "余分な検索パラメーターがあります。#{left_options.inspect}"
            end

            # AreSearch::DumpBody は廃止
            return body if dump_body_opts == true


            # --- 変換 ---
            model_includes        = (model_includes_opts.nil? ? {} : model_includes_opts)
            model_results_wheres  = (model_results_where_opts.nil? ? {} : model_results_where_opts)

            page     = AreSearch::SearcherUtils.resolve_default_option(page_opts, 1)
            per_page = AreSearch::SearcherUtils.resolve_default_option(per_page_opts, 25)

            return empty_search_result(page, per_page, params_invalid: true) unless AreSearch::EsSearchBodyPolicy.valid?(body)
            return empty_search_result(page, per_page)                       unless check_index_exists?(index_targets)

            # --- 結果復元情報 ---
            result_context = {
                index_to_index_target: build_index_to_index_target(index_targets),
                model_includes:        model_includes,
                model_results_wheres:  model_results_wheres,
                page:                  page,
                per_page:              per_page,
            }

            search_index = index_targets.map(&:are_search_es_index_name).join(",")
            execute_and_build_result(search_index, body, result_context)
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

        private

        # index_targets から重複しないモデル一覧を作る
        def index_targets_to_models(index_targets)
            index_targets.map(&:model_class).uniq
        end

        # モデルが Searchable を include しているか確認する
        def verify_searchable!(model)
            unless model.include?(AreSearch::Searchable)
                raise ArgumentError, "#{model.name} は AreSearch::Searchable を include していません"
            end
        end

        # 初期化中ようの空のresult
        def empty_search_result(page, per_page, params_invalid: false)
            paginated = PaginatedCollection.new(
                [],
                current_page:   page,
                per_page:       per_page,
                total_count:    0,
                es_total_count: 0,
            )
            SearchResult.new([], paginated, {}, {}, params_invalid: params_invalid)
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
            model_results_wheres = result_context[:model_results_wheres]
            page = result_context[:page]
            per_page = result_context[:per_page]

            record_result = build_records(
                hits,
                index_to_index_target,
                model_includes,
                model_results_wheres,
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
        def build_records(hits, index_to_index_target, model_includes, model_results_wheres)
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
                        ids_by_index_target[index_target] << hit["_id"]
                    end
                else
                    if model_class_names == index_target.model_class.name
                        ids_by_index_target[index_target] << hit["_id"]
                    end
                end
            end

            # index_targetごとにDBから取得。複合キー: "#{es_index_name}/#{id}"
            records_by_composite_key = {}
            ids_by_index_target.each do |index_target, ids|
                model = index_target.model_class

                relation = model.where(id: ids)
                # DB追加条件で取得対象を確定してから includes を付与する
                relation = relation.where(model_results_wheres[model]) if model_results_wheres[model].present?

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

        # hits から { composite_key => source } の Hash を組み立てる
        def build_hit_source_hash(hits, index_to_index_target)
            result = {}
            hits.each do |hit|
                index_target = index_target_for_hit_index(index_to_index_target, hit["_index"])
                next if index_target.nil?

                key = index_target.are_search_es_composite_key(hit["_id"])
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

                key = index_target.are_search_es_composite_key(hit["_id"])
                next if key.nil?

                fragments = (hit["highlight"] || {}).values.flatten(1)
                result[key] = fragments
            end
            result
        end
    end
end
