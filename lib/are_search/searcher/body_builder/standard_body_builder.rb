# frozen_string_literal: true

module AreSearch
    class StandardBodyBuilder < BodyBuilderBase
        class << self
            def must_params
                [
                ].freeze
            end

            def must_not_params
                [
                    :raw_body,
                ].freeze
            end

            # 検証済みの検索オプションから標準 Elasticsearch body を組み立てる。
            def build(index_targets, query, valid_options)
                # 使うオプションだけ取る
                aggs_opts                = valid_options.delete(:aggs)
                page_opt                 = valid_options.delete(:page)
                per_page_opt             = valid_options.delete(:per_page)
                sort_opts                = valid_options.delete(:sort)
                highlight_opts           = valid_options.delete(:highlight)


                # --- 変換 ---
                page                 = AreSearch::SearcherUtils.resolve_default_option(page_opt, 1)
                per_page             = AreSearch::SearcherUtils.resolve_default_option(per_page_opt, 25)
                normalized_sort      = normalize_sort_options(sort_opts)
                normalized_highlight = normalize_highlight_options(highlight_opts)

                from = (page - 1) * per_page
                size = per_page
                es_from, es_size = resolve_paging_params(index_targets, from, size)

                body = {
                    track_total_hits: true,
                    from:  es_from,
                    size:  es_size,
                    query: query,
                }
                if aggs_opts.nil? == false
                    body[:aggs] = build_aggs(aggs_opts)
                end

                body[:sort] = normalized_sort if normalized_sort.present?
                body[:highlight] = normalized_highlight if normalized_highlight.nil? == false

                return body
            end

            private

            # Hash形式のsortを、記述順を維持したElasticsearch用Arrayへ変換する。
            def normalize_sort_options(sort_opts)
                return nil if sort_opts.nil?
                return sort_opts unless sort_opts.instance_of?(Hash)

                normalized_sort = []

                sort_opts.each do |field_name, order|
                    normalized_sort << {
                        field_name => order,
                    }
                end

                normalized_sort
            end

            # highlight を fields が Hash の共通形式へ変換する
            def normalize_highlight_options(highlight_opts)
                return nil if highlight_opts.nil?
                return nil if highlight_opts[:fields].nil?

                normalized_fields = {}
                highlight_fields = highlight_opts[:fields]

                if highlight_fields.instance_of?(Hash)
                    highlight_fields.each do |field_name, field_options|
                        normalized_fields[field_name] = field_options
                    end
                else
                    highlight_fields.each do |field_name|
                        normalized_fields[field_name] = {}
                    end
                end

                return nil if normalized_fields.empty?

                normalized_options = {}
                highlight_opts.each do |key, value|
                    next if key == :fields

                    normalized_options[key] = value
                end
                normalized_options[:fields] = normalized_fields

                normalized_options
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

            # フィールド別の terms オプションから ES リクエスト用の aggs を組み立てる。
            def build_aggs(aggs_opts)
                result = {}

                aggs_opts.each do |field, terms_options|
                    es_terms_options = terms_options.dup
                    es_terms_options[:field] = field

                    result[field] = { terms: es_terms_options }
                end

                result
            end
        end
    end
end
