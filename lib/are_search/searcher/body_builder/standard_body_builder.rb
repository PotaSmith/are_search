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
                normalized_aggs      = normalize_aggs(aggs_opts)

                page                 = AreSearch::SearcherUtils.resolve_default_option(page_opt, 1)
                per_page             = AreSearch::SearcherUtils.resolve_default_option(per_page_opt, 25)
                normalized_sort      = sort_opts
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
                body[:aggs] = build_aggs(normalized_aggs) if normalized_aggs.any?
                body[:sort] = normalized_sort if normalized_sort.present?
                body[:highlight] = build_highlight_body(normalized_highlight) unless normalized_highlight.nil?

                return body
            end

            private

            # aggs を共通の field / terms_options 形式へ変換する
            def normalize_aggs(aggs_opts)
                normalized_aggs = []
                return normalized_aggs if aggs_opts.nil?

                aggs_opts.each do |entry|
                    if entry.instance_of?(Hash)
                        entry.each do |field, terms_options|
                            normalized_options = { size: AreSearch.default_aggs_size }

                            terms_options.each do |key, value|
                                normalized_options[key] = value
                            end

                            normalized_aggs << { field: field, terms_options: normalized_options }
                        end
                    else
                        normalized_aggs << {
                            field: entry,
                            terms_options: { size: AreSearch.default_aggs_size },
                        }
                    end
                end

                normalized_aggs
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
                    highlight_fields.each do |field_entry|
                        if field_entry.instance_of?(Hash)
                            field_entry.each do |field_name, field_options|
                                normalized_fields[field_name] = field_options
                            end
                        else
                            normalized_fields[field_entry] = {}
                        end
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

            # normalized_aggs から ES リクエスト用の aggs ハッシュを組み立てる
            def build_aggs(normalized_aggs)
                result = {}

                normalized_aggs.each do |agg|
                    field = agg[:field]
                    terms_options = agg[:terms_options].dup
                    terms_options[:field] = field

                    result[field] = { terms: terms_options }
                end

                result
            end

            # normalized_highlight から ES リクエスト用の highlight body を組み立てる
            def build_highlight_body(normalized_highlight)
                body = {
                    pre_tags:  AreSearch::SearchResult::HIGHLIGHT_PRE_TAGS,
                    post_tags: AreSearch::SearchResult::HIGHLIGHT_POST_TAGS,
                    encoder:   "html",
                }

                normalized_highlight.each do |key, value|
                    body[key] = value
                end

                body
            end
        end
    end
end
