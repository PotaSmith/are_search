# frozen_string_literal: true

module AreSearch
    class IndexTarget

        # 単一の index target を Searcher で検索する。
        # query・fields・query_type は1件の queries へ変換する。
        # 指定された relation は、対象モデルを key にした model_relations へ変換して渡す。
        #
        # @return [SearchResult]
        #
        def are_search_search(query, **options)
            unsupported_options = []
            [:model_relations, :queries].each do |option_name|
                if options.key?(option_name)
                    unsupported_options << option_name
                end
            end
            if unsupported_options.any?
                raise ArgumentError,
                    "are_search_search に未知のオプションが指定されています: #{unsupported_options.inspect}"
            end

            model = model_class
            index_targets = [self]
            relation_opt = options.delete(:relation)
            query_options = {
                query_string: query,
            }
            if options.key?(:fields)
                query_options[:fields] = options.delete(:fields)
            end
            if options.key?(:query_type)
                query_options[:query_type] = options.delete(:query_type)
            end

            if relation_opt.nil? == false
                options[:model_relations] = {
                    model => relation_opt,
                }
            end

            AreSearch::Searcher.search(index_targets, queries: [query_options], **options)
        end
    end

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
            max_result_window = resolve_max_result_window(index_targets)

            begin
                valid_options = SearchParamValidator.validate!(index_targets, models, max_result_window, **options)
                AreSearch.search_param_policy.validate!(valid_options)
            rescue AreSearch::InvalidSearchOption => error
                return search_failure_result(
                    status: SearchResult::STATUS_PARAMS_INVALID,
                    error_class: AreSearch::InvalidSearchOption,
                    error_message: error.message,
                )
            end

            index_targets_for_exists_check = collect_index_targets_for_exists_check(index_targets, valid_options)
            if index_ready?(index_targets_for_exists_check) == false
                return search_failure_result(
                    status: SearchResult::STATUS_INDEX_NOT_FOUND,
                    error_class: AreSearch::SearchIndexNotFound,
                    error_message: "検索に必要な index が確認できません",
                )
            end

            query_options = valid_options.dup
            body_options = valid_options.dup
            query = AreSearch::QueryBuilderSelector.select(valid_options).build(index_targets, query_options)
            body = AreSearch::BodyBuilderSelector.select(valid_options).build(index_targets, query, body_options, max_result_window)

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

            if runtime_mappings_exists == true && enable_runtime_mappings_opts != true
                raise ArgumentError, "runtime_mappings を使用する場合は enable_runtime_mappings: true を指定してください"
            end

            # --- 変換 ---
            model_relations = {}
            if model_relations_opts.nil? == false
                model_relations = model_relations_opts
            end

            body_for_policy = body.dup
            body_for_policy.delete(:runtime_mappings)
            body_for_policy.delete("runtime_mappings")

            if AreSearch.search_body_policy.valid?(body_for_policy) != true
                return search_failure_result(
                    status: SearchResult::STATUS_PARAMS_INVALID,
                    error_class: AreSearch::InvalidSearchBody,
                    error_message: "検索bodyがsearch_body_policyに拒否されました",
                )
            end

            index = index_targets.map(&:are_search_index_alias_name).join(",")
            # 検索
            response = AreSearch::EsAdapter.no_validation_search(index: index, body: body)

            page     = AreSearch::SearcherUtils.resolve_page_default_option(page_opts, 1)
            per_page = AreSearch::SearcherUtils.resolve_page_default_option(per_page_opts, 25)

            build_result(
                response,
                build_index_to_index_targets(index_targets),
                model_relations,
                page,
                per_page,
                max_result_window,
            )
        rescue AreSearch::SearchIndexNotFound, AreSearch::InvalidSearchOption, AreSearch::InvalidSearchBody
            raise
        rescue StandardError => error
            raise if AreSearch.search_failure_mode == :raise

            AreSearch.logger.error "[search fail: #{error.class}]\n#{error.message}"
            empty_search_result(1, 25, status: SearchResult::STATUS_SEARCH_FAIL)
        end

        def index_ready?(index_targets)
            begin
                check_index_exists?(index_targets) == true
            rescue StandardError
                false
            end
        end

        def check_index_exists?(index_targets)
            index_targets.all? do |index_target|
                index_target.are_search_index_alias_exists?
            end
        end

        private

        # 検索対象 IndexTarget 群で使用できる最小の max_result_window を返す。
        def resolve_max_result_window(index_targets)
            values = index_targets.map { |index_target|
                index_target.are_search_index_settings[:max_result_window]
            }

            values.min
        end

        # 検索で参照する全aliasの存在確認対象を、検索対象とオプションから集める。
        def collect_index_targets_for_exists_check(index_targets, options)
            additional_index_targets = []

            mlt_options = options[:mlt]
            if mlt_options.nil? == false
                additional_index_targets << mlt_options[:like][:index_target]
            end

            index_targets_for_exists_check = index_targets + additional_index_targets
            index_targets_for_exists_check.uniq { |index_target| index_target.are_search_index_alias_name }
        end

        # index_targets から重複しないモデル一覧を作る
        def index_targets_to_models(index_targets)
            index_targets.map(&:model_class).uniq
        end

        # モデルが Searchable を include しているか確認する
        def verify_searchable!(model)
            if model.include?(AreSearch::Searchable) == false
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
                    next if index_target.are_search_index_alias_name.to_s != other_index_target.are_search_index_alias_name.to_s

                    model = index_target.model_class
                    other_model = other_index_target.model_class
                    if model < other_model
                        raise ArgumentError,
                            "同じ Elasticsearch index に親子関係のあるモデルを同時指定できません: " \
                            "#{index_target.are_search_index_alias_name}: #{other_model.name}, #{model.name}"
                    end
                end
            end
        end

        # 検索を実行できない場合に、設定に従って例外または空結果を返す。
        def search_failure_result(status:, error_class:, error_message:)
            if AreSearch.search_failure_mode == :raise
                raise error_class, error_message
            end

            empty_search_result(1, 25, status: status)
        end

        # 検索を実行せず返す空結果を、終了理由の status 付きで作る。
        def empty_search_result(page, per_page, status: SearchResult::STATUS_OK)
            SearchResult.new(
                [],
                [],
                page:              page,
                per_page:          per_page,
                es_total_count:    0,
                hits_count:        0,
                max_result_window: 0,
                status:            status,
            )
        end

        # index_targets から { index_alias_name => [index_target] } の逆引きマップを組み立てる。
        # 同じ alias に複数 target がある場合も、候補を指定順で保持する。
        def build_index_to_index_targets(index_targets)
            result = {}

            index_targets.each do |index_target|
                index_alias_name = index_target.are_search_index_alias_name.to_s
                result[index_alias_name] ||= []
                result[index_alias_name] << index_target
            end

            result
        end

        #########################################################################
        # result生成
        #########################################################################

        # ES リクエストを実行し、結果復元情報を使って SearchResult を組み立てる
        def build_result(response, index_to_index_targets, model_relations, page, per_page, max_result_window)

            records = []
            records_with_hit = []
            es_total_count = 0
            hits_count = 0

            hits = response.dig("hits", "hits")

            if hits.nil? == false
                es_total_count = response.dig("hits", "total", "value").to_i
                hits_count = hits.size

                if hits.all? { |hit| hit["_source"].nil? == false }
                    record_result = build_records_results(hits, index_to_index_targets, model_relations)

                    records = record_result[:records]
                    records_with_hit = record_result[:records_with_hit]
                end
            end

            SearchResult.new(
                records,
                records_with_hit,
                page:              page,
                per_page:          per_page,
                es_total_count:    es_total_count,
                hits_count:        hits_count,
                max_result_window: max_result_window,
                raw_response:      response,
            )
        end

        #########################################################################
        # レコード関連生成
        #########################################################################

        # ヒット一覧からレコードを復元し、対応する target・_source・highlight とともに検索順で返す
        def build_records_results(hits, index_to_index_targets, model_relations)
            # index_targetごとにElasticsearchのkeyを集める。
            es_keys_by_index_target = {}
            hits.each do |hit|
                index_targets = index_targets_for_hit_index(index_to_index_targets, hit["_index"])
                if index_targets.blank?
                    AreSearch.logger.warn { "[AreSearch] unknown index: #{hit["_index"]}" }
                    next
                end

                index_targets.each do |index_target|
                    next unless hit_matches_index_target?(hit, index_target)

                    es_keys_by_index_target[index_target] ||= []
                    es_keys_by_index_target[index_target] << hit["_id"]
                end
            end

            # index_targetごとにDBから取得し、Elasticsearchのkeyで参照できる形で保持する。
            records_by_index_target = {}
            es_keys_by_index_target.each do |index_target, es_keys|
                model = index_target.model_class
                relation = model_relations[model]

                if relation.nil?
                    relation = model.where(id: es_keys)
                else
                    relation = relation.where(id: es_keys)
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
                        index_target_name: index_target.index_target_name,
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
                hit["_source"][AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s]

            if model_class_names.instance_of?(Array)
                return model_class_names.include?(index_target.model_class.name)
            end

            model_class_names == index_target.model_class.name
        end

        # index_to_index_targets は alias 名をキーにした index target 候補配列の map。
        def index_targets_for_hit_index(index_to_index_targets, hit_index)
            # Elasticsearch の hit に含まれる物理 index 名から alias 名を復元する。
            index_alias_name = AreSearch::IndexDefinition.index_alias_name_from_physical_index_name(hit_index)

            # AreSearch の物理 index 命名形式でなければ対応する target はない。
            return nil if index_alias_name.nil?

            index_to_index_targets[index_alias_name]
        end
    end
end
