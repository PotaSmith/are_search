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
            verify_no_parent_child_index_targets!(index_targets)

            valid_options = SearchParamValidator.validate(index_targets, models, **options)

            query_options = valid_options.dup
            body_options = valid_options.dup
            query = AreSearch::QueryBuilderSelector.select(valid_options).build(index_targets, query_options)
            body = AreSearch::BodyBuilderSelector.select(valid_options).build(index_targets, query, body_options)

            # ここで使うオプションを取る
            search_options = valid_options.dup

            model_relations_opts = search_options.delete(:model_relations)
            page_opts            = search_options.delete(:page)
            per_page_opts        = search_options.delete(:per_page)
            dump_body_opts       = search_options.delete(:dump_body)

            # 未使用のオプションがあるか
            left_options = query_options.keys & body_options.keys & search_options.keys
            if left_options.any?
                raise ArgumentError, "余分な検索パラメーターがあります。#{left_options.inspect}"
            end

            # AreSearch::DumpBody は廃止
            return body if dump_body_opts == true


            # --- 変換 ---
            model_relations = {}
            if model_relations_opts.nil? == false
                model_relations = model_relations_opts
            end

            page     = AreSearch::SearcherUtils.resolve_default_option(page_opts, 1)
            per_page = AreSearch::SearcherUtils.resolve_default_option(per_page_opts, 25)

            return empty_search_result(page, per_page, params_invalid: true) unless AreSearch.es_search_body_policy.valid?(body)
            return empty_search_result(page, per_page)                       unless check_index_exists?(index_targets)

            # --- 結果復元情報 ---
            result_context = {
                index_to_index_targets: build_index_to_index_targets(index_targets),
                model_relations:       model_relations,
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

        # 同じ alias を使う index target に親子関係が含まれていないことを確認する。
        # 親子を同時指定すると同じhitが両方のtargetに一致し、復元先を一意に決められない。
        def verify_no_parent_child_index_targets!(index_targets)
            index_targets.each do |index_target|
                index_targets.each do |other_index_target|
                    next if index_target == other_index_target
                    next unless index_target.are_search_es_index_name.to_s == other_index_target.are_search_es_index_name.to_s

                    model = index_target.model_class
                    other_model = other_index_target.model_class
                    next unless model < other_model

                    raise ArgumentError,
                        "同じ Elasticsearch index に親子関係のあるモデルを同時指定できません: " \
                        "#{index_target.are_search_es_index_name}: #{other_model.name}, #{model.name}"
                end
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

        # index_targets から { es_index_name => [index_target] } の逆引きマップを組み立てる。
        # 同じ alias の親子関係は検索開始時に拒否済みなので、候補をそのまま保持する。
        def build_index_to_index_targets(index_targets)
            result = {}

            index_targets.each do |index_target|
                alias_name = index_target.are_search_es_index_name.to_s
                result[alias_name] ||= []
                result[alias_name] << index_target
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

            index_to_index_targets = result_context[:index_to_index_targets]
            model_relations = result_context[:model_relations]
            page = result_context[:page]
            per_page = result_context[:per_page]

            record_result = build_records(
                hits,
                index_to_index_targets,
                model_relations,
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

            hit_sources = build_hit_source_hash(hits, index_to_index_targets)

            highlights = {}

            # SearchResult の highlight は、hit にフラグメントが返ったかではなく、
            # 検索 body で highlight を要求した場合だけ復元する。
            # RawSearch は body の key を変換しないため、Symbol / String の両方を見る。
            highlight_requested = search_body[:highlight].present?
            if highlight_requested == false
                highlight_requested = search_body["highlight"].present?
            end

            if highlight_requested
                highlights = build_highlights_hash(hits, index_to_index_targets)
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

        # index_to_index_targets は alias 名をキーにした index target 候補配列の map。
        def index_targets_for_hit_index(index_to_index_targets, hit_index)
            # Elasticsearch の hit に含まれる実体 index 名。
            index_name = hit_index.to_s

            # 旧方式の、alias 名と同名の実体 index を検索した場合。
            index_targets = index_to_index_targets[index_name]
            return index_targets unless index_targets.nil?

            # timestamp 付き物理 index 名から、生成元の alias 名を復元する。
            alias_name = AreSearch::IndexManager.es_alias_name_from_index_name(index_name)

            # AreSearch の物理 index 命名形式でなければ対応する target はない。
            return nil if alias_name.nil?

            index_to_index_targets[alias_name]
        end


        # hit に保存された Searchable 継承系統へ検索対象モデルが含まれるか判定する。
        def hit_matches_index_target?(hit, index_target)
            model_class_names =
                hit["_source"][AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s]

            if model_class_names.instance_of?(Array)
                return model_class_names.include?(index_target.model_class.name)
            end

            model_class_names == index_target.model_class.name
        end

        # ヒット一覧からActiveRecordオブジェクトを復元し、ヒット順に並べて返す
        def build_records(hits, index_to_index_targets, model_relations)
            empty_result = {
                records:                   [],
                records_with_target_names: [],
            }
            return empty_result if hits.empty?

            # index_targetごとにidを集める
            ids_by_index_target = {}
            hits.each do |hit|
                index_targets = index_targets_for_hit_index(index_to_index_targets, hit["_index"])
                if index_targets.blank?
                    AreSearch.logger.warn { "[AreSearch] unknown index: #{hit["_index"]}" }
                    next
                end

                index_targets.each do |index_target|
                    next unless hit_matches_index_target?(hit, index_target)

                    ids_by_index_target[index_target] ||= []
                    ids_by_index_target[index_target] << hit["_id"]
                end
            end

            # index_targetごとにDBから取得。複合キー: "#{es_index_name}/#{id}"
            records_by_composite_key = {}
            ids_by_index_target.each do |index_target, ids|
                model = index_target.model_class
                relation = model_relations[model]

                if relation.nil?
                    relation = model.where(id: ids)
                else
                    relation = relation.where(id: ids)
                end

                relation.each do |record|
                    key = index_target.are_search_es_composite_key(record.id)
                    records_by_composite_key[key] = record
                end
            end

            records = []
            records_with_target_names = []

            # ヒット順に並び替え
            hits.each do |hit|
                index_targets = index_targets_for_hit_index(index_to_index_targets, hit["_index"])
                next if index_targets.blank?

                index_targets.each do |index_target|
                    next unless hit_matches_index_target?(hit, index_target)

                    key = index_target.are_search_es_composite_key(hit["_id"])
                    next if key.nil?

                    record = records_by_composite_key[key]
                    next if record.nil?

                    records << record
                    records_with_target_names << [record, index_target.target_name]
                    break
                end
            end

            {
                records:                   records,
                records_with_target_names: records_with_target_names,
            }
        end

        # hits から { composite_key => source } の Hash を組み立てる
        def build_hit_source_hash(hits, index_to_index_targets)
            result = {}
            hits.each do |hit|
                index_targets = index_targets_for_hit_index(index_to_index_targets, hit["_index"])
                next if index_targets.blank?

                index_target = index_targets.first
                key = index_target.are_search_es_composite_key(hit["_id"])
                next if key.nil?

                source    = (hit["_source"] || {}).transform_keys(&:to_sym)
                result[key] = source
            end
            result
        end

        # hits から { composite_key => { field => fragments } } の highlight Hash を組み立てる。
        def build_highlights_hash(hits, index_to_index_targets)
            result = {}
            hits.each do |hit|
                index_targets = index_targets_for_hit_index(index_to_index_targets, hit["_index"])
                next if index_targets.blank?

                index_target = index_targets.first
                key = index_target.are_search_es_composite_key(hit["_id"])
                next if key.nil?

                highlight = hit["highlight"] || {}
                result[key] = highlight.transform_keys(&:to_sym)
            end
            result
        end
    end
end
