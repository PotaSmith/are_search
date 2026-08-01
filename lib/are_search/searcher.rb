# frozen_string_literal: true

module AreSearch
    module Searcher
        extend self

        # 複数の index target を横断して検索する
        def search(index_targets, **options)
            raise ArgumentError, "index_targets を指定してください" if index_targets.nil?
            raise ArgumentError, "index_targets は1件以上指定してください" if index_targets.empty?

            verify_no_duplicate_index_targets!(index_targets)

            models = index_targets_to_models(index_targets)
            models.each do |model|
                verify_searchable!(model)
            end
            verify_no_parent_child_index_targets!(index_targets)

            valid_options, error_message = SearchParamValidator.validate(index_targets, models, **options)

            if error_message.nil? == false
                return search_failure_result(
                    1,
                    25,
                    status: SearchResult::STATUS_PARAMS_INVALID,
                    error_class: AreSearch::InvalidSearchOption,
                    error_message: error_message,
                )
            end

            query_options = valid_options.dup
            body_options = valid_options.dup
            query = AreSearch::QueryBuilderSelector.select(valid_options).build(index_targets, query_options)
            body = AreSearch::BodyBuilderSelector.select(valid_options).build(index_targets, query, body_options)

            # ここで使うオプションを取る
            search_options = valid_options.dup

            model_relations_opts = search_options.delete(:model_relations)
            page_opts            = search_options.delete(:page)
            per_page_opts        = search_options.delete(:per_page)

            enable_runtime_mappings_opts = search_options.delete(:enable_runtime_mappings)
            dump_body_opts               = search_options.delete(:dump_body)

            # 未使用のオプションがあるか
            left_options = query_options.keys & body_options.keys & search_options.keys
            if left_options.any?
                raise ArgumentError, "余分な検索パラメーターがあります。#{left_options.inspect}"
            end

            return body if dump_body_opts == true

            runtime_mappings_exists = body.key?(:runtime_mappings) || body.key?("runtime_mappings")

            if runtime_mappings_exists && enable_runtime_mappings_opts != true
                raise ArgumentError,
                    "runtime_mappings を使用する場合は enable_runtime_mappings: true を指定してください"
            end

            # --- 変換 ---
            model_relations = {}
            if model_relations_opts.nil? == false
                model_relations = model_relations_opts
            end

            page     = AreSearch::SearcherUtils.resolve_default_option(page_opts, 1)
            per_page = AreSearch::SearcherUtils.resolve_default_option(per_page_opts, 25)

            body_for_policy = body.dup
            body_for_policy.delete(:runtime_mappings)
            body_for_policy.delete("runtime_mappings")

            if AreSearch.es_search_body_policy.valid?(body_for_policy) == false
                return search_failure_result(
                    page,
                    per_page,
                    status: SearchResult::STATUS_PARAMS_INVALID,
                    error_class: AreSearch::InvalidSearchBody,
                    error_message: "検索bodyがes_search_body_policyに拒否されました",
                )
            end

            index_targets_for_exists_check = collect_index_targets_for_exists_check(index_targets, valid_options)
            if check_index_exists?(index_targets_for_exists_check) == false
                return search_failure_result(
                    page,
                    per_page,
                    status: SearchResult::STATUS_INDEX_NOT_FOUND,
                    error_class: AreSearch::SearchIndexNotFound,
                    error_message: "検索に必要なElasticsearch aliasが存在しません",
                )
            end

            search_index = index_targets.map(&:are_search_es_index_name).join(",")
            # 検索
            response = AreSearch.client.search(index: search_index, body: body)

            build_result(
                response,
                build_index_to_index_targets(index_targets),
                model_relations,
                page,
                per_page,
            )
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

        # 検索で参照する全aliasの存在確認対象を、検索対象とオプションから集める。
        def collect_index_targets_for_exists_check(index_targets, options)
            additional_index_targets = []

            mlt_options = options[:mlt]
            if mlt_options.nil? == false
                additional_index_targets << mlt_options[:index_target]
            end

            index_targets_for_exists_check = index_targets + additional_index_targets
            index_targets_for_exists_check.uniq { |index_target| index_target.are_search_es_index_name }
        end

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

        # 同じIndexTargetが複数指定されていないことを確認する。
        def verify_no_duplicate_index_targets!(index_targets)
            return if index_targets.uniq.size == index_targets.size

            raise ArgumentError, "同じ index target は複数指定できません"
        end

        # 同じ alias を使う index target に親子関係が含まれていないことを確認する。
        # 親子を同時指定すると1つのhitが複数レコードへ展開され、
        # Elasticsearchのhit単位のページングとrecordsの件数が一致しない。
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

        # 検索を実行できない場合に、設定に従って例外または空結果を返す。
        def search_failure_result(page, per_page, status:, error_class:, error_message:)
            if AreSearch.search_failure_mode == :raise
                raise error_class, error_message
            end

            empty_search_result(page, per_page, status: status)
        end

        # 検索を実行せず返す空結果を、終了理由の status 付きで作る。
        def empty_search_result(page, per_page, status: SearchResult::STATUS_OK)
            paginated = PaginatedCollection.new(
                [],
                current_page:   page,
                per_page:       per_page,
                total_count:    0,
                es_total_count: 0,
            )
            SearchResult.new(paginated, [], {}, {}, status: status)
        end

        # index_targets から { es_index_name => [index_target] } の逆引きマップを組み立てる。
        # 同じ alias に複数 target がある場合も、候補を指定順で保持する。
        def build_index_to_index_targets(index_targets)
            result = {}

            index_targets.each do |index_target|
                alias_name = index_target.are_search_es_index_name.to_s
                result[alias_name] ||= []
                result[alias_name] << index_target
            end

            result
        end

        #########################################################################
        # result生成
        #########################################################################

        # ES リクエストを実行し、結果復元情報を使って SearchResult を組み立てる
        def build_result(response, index_to_index_targets, model_relations, page, per_page)

            paginated_results = build_paginated_results(response, index_to_index_targets, model_relations, page, per_page)

            aggs_results = build_aggs_results(response)

            SearchResult.new(
                paginated_results[:paginated_records],
                paginated_results[:records_with_hit],
                aggs_results[:aggs],
                aggs_results[:str_key_aggs],
                raw_response: response,
            )
        end

        #########################################################################
        # 簡易アクセスaggs生成
        #########################################################################

        # Array形式のbucketを、内部キー用と表示用の簡易結果へ変換する。
        # keyがないbucketはdoc_countだけを結果へ追加する。
        def build_aggs_results(response)
            aggregations = response["aggregations"]

            if aggregations.nil?
                return { aggs: {}, str_key_aggs: {} }
            end

            aggs = {}
            str_key_aggs = {}

            aggregations.each do |name, agg|
                buckets = agg["buckets"]
                next if buckets.nil?
                next if buckets.instance_of?(Array) == false

                agg_result = []
                str_key_agg_result = []

                buckets.each do |bucket|
                    if bucket.key?("key")
                        # keyがある通常のbucket
                        key = bucket["key"]
                        str_key = key

                        if bucket.key?("key_as_string")
                            str_key = bucket["key_as_string"]
                        end

                        doc_count = bucket["doc_count"]
                        agg_result << [key, doc_count]
                        str_key_agg_result << [str_key, doc_count]
                    else
                        # keyがないbucket
                        doc_count = bucket["doc_count"]
                        agg_result << doc_count
                        str_key_agg_result << doc_count
                    end
                end

                name_key = name.to_sym
                aggs[name_key] = agg_result
                str_key_aggs[name_key] = str_key_agg_result
            end

            { aggs: aggs, str_key_aggs: str_key_aggs }
        end

        #########################################################################
        # レコード関連生成
        #########################################################################

        def build_paginated_results(response, index_to_index_targets, model_relations, page, per_page)
            hits = response.dig("hits", "hits")

            if hits.nil?
                return empty_paginated_results(page, per_page, 0)
            end

            es_total_count = response.dig("hits", "total", "value").to_i

            if hits.any? { |hit| hit["_source"].nil? }
                return empty_paginated_results(page, per_page, es_total_count)
            end

            record_result    = build_records_results(hits, index_to_index_targets, model_relations)
            records          = record_result[:records]
            records_with_hit = record_result[:records_with_hit]

            total_count =  build_display_total_count(es_total_count, hits, records)

            paginated_records = PaginatedCollection.new(
                records,
                current_page:   page,
                per_page:       per_page,
                total_count:    total_count,
                es_total_count: es_total_count,
            )

            {
                paginated_records: paginated_records,
                records_with_hit:  records_with_hit,
            }
        end

        def empty_paginated_results(page, per_page, es_total_count)
            paginated_records = PaginatedCollection.new(
                [],
                current_page:   page,
                per_page:       per_page,
                total_count:    0,
                es_total_count: es_total_count,
            )

            {
                paginated_records: paginated_records,
                records_with_hit:  [],
            }
        end

        # ヒット一覧からレコードを復元し、対応する target・_source・highlight とともに検索順で返す
        def build_records_results(hits, index_to_index_targets, model_relations)
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

            # index_targetごとにDBから取得し、idをキーに保持する。
            records_by_index_target = {}
            ids_by_index_target.each do |index_target, ids|
                model = index_target.model_class
                relation = model_relations[model]

                if relation.nil?
                    relation = model.where(id: ids)
                else
                    relation = relation.where(id: ids)
                end

                records_for_index_target = {}
                relation.each do |record|
                    records_for_index_target[record.id.to_s] = record
                end
                records_by_index_target[index_target] = records_for_index_target
            end

            records = []
            records_with_hit = []

            # ヒット順に並び替え
            hits.each do |hit|
                index_targets = index_targets_for_hit_index(index_to_index_targets, hit["_index"])
                next if index_targets.blank?

                index_targets.each do |index_target|
                    next unless hit_matches_index_target?(hit, index_target)

                    records_for_index_target = records_by_index_target[index_target]
                    next if records_for_index_target.nil?

                    record = records_for_index_target[hit["_id"].to_s]
                    next if record.nil?

                    source    = (hit["_source"]   || {}).transform_keys(&:to_sym)
                    highlight = (hit["highlight"] || {}).transform_keys(&:to_sym)
                    fields    = (hit["fields"]    || {}).transform_keys(&:to_sym)

                    hit_info = {
                        index: hit["_index"],
                        id: hit["_id"],
                        highlight: highlight,
                        source: source,
                        fields: fields,
                        target_name: index_target.target_name,
                    }
                    records          << record
                    records_with_hit << [record, hit_info]
                end
            end

            {
                records:          records,
                records_with_hit: records_with_hit,
            }
        end

        # hit に保存された Searchable 継承系統へ検索対象モデルが含まれるか判定する。
        def hit_matches_index_target?(hit, index_target)
            model_class_names =
                hit["_source"][AreSearch::IndexDefinition::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s]

            if model_class_names.instance_of?(Array)
                return model_class_names.include?(index_target.model_class.name)
            end

            model_class_names == index_target.model_class.name
        end

        # index_to_index_targets は alias 名をキーにした index target 候補配列の map。
        def index_targets_for_hit_index(index_to_index_targets, hit_index)
            # Elasticsearch の hit に含まれる物理 index 名から alias 名を復元する。
            alias_name = AreSearch::IndexDefinition.es_alias_name_from_index_name(hit_index)

            # AreSearch の物理 index 命名形式でなければ対応する target はない。
            return nil if alias_name.nil?

            index_to_index_targets[alias_name]
        end

        def build_display_total_count(es_total_count, hits, records)
            dropped_count = hits.size - records.size
            dropped_count = 0 if dropped_count < 0

            total_count = es_total_count - dropped_count
            total_count = 0 if total_count < 0

            total_count
        end

    end
end
