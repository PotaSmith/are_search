# frozen_string_literal: true

module AreSearch
    class StandardBodyBuilder < BodyBuilderBase

        # aggs の Array 簡易形式で terms aggregation へ指定する bucket 数。
        DEFAULT_AGGS_SIZE = 200

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
                runtime_mappings_opts  = valid_options.delete(:runtime_mappings)
                aggs_opts              = valid_options.delete(:aggs)
                page_opt               = valid_options.delete(:page)
                per_page_opt           = valid_options.delete(:per_page)
                sort_opts              = valid_options.delete(:sort)
                highlight_opts         = valid_options.delete(:highlight)
                response_opts          = valid_options.delete(:response)

                # --- 変換 ---
                page                 = AreSearch::SearcherUtils.resolve_default_option(page_opt, 1)
                per_page             = AreSearch::SearcherUtils.resolve_default_option(per_page_opt, 25)
                normalized_sort      = normalize_sort_options(sort_opts)
                normalized_highlight = normalize_highlight_options(highlight_opts)
                response_source      = build_response_source(response_opts)
                response_fields      = build_response_fields(response_opts)

                from = (page - 1) * per_page
                size = per_page
                es_from, es_size = resolve_paging_params(index_targets, from, size)

                body = {
                    track_total_hits: true,
                    from:    es_from,
                    size:    es_size,
                    query:   query,
                    _source: response_source,
                }
                if aggs_opts.nil? == false
                    body[:aggs] = build_aggs(aggs_opts)
                end

                body[:sort] = normalized_sort if normalized_sort.present?
                body[:highlight] = normalized_highlight if normalized_highlight.nil? == false
                body[:fields] = response_fields if response_fields.nil? == false
                if runtime_mappings_opts.nil? == false
                    body[:runtime_mappings] = runtime_mappings_opts
                end

                return body
            end

            private

            # 検索結果へ返す_sourceを、復元用予約フィールドと利用側指定から作る。
            # 利用側指定はsource pathとして扱い、mappingとの照合は行わない。
            def build_response_source(response_opts)
                source_fields = []

                AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAMES.each do |reserved_field_name|
                    source_fields << reserved_field_name.to_s
                end

                return source_fields if response_opts.nil?

                configured_source_fields = response_opts[:source]
                return source_fields if configured_source_fields.nil?

                configured_source_fields.each do |field_name|
                    next if source_fields.include?(field_name)

                    source_fields << field_name
                end

                source_fields
            end

            # 検索結果へ返すfields指定をそのまま返す。
            # runtime fieldやfield patternを許容するためmappingとの照合は行わない。
            def build_response_fields(response_opts)
                return nil if response_opts.nil?

                response_opts[:fields]
            end

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

                normalized_options = {}
                highlight_opts.each do |key, value|
                    next if key == :fields

                    normalized_options[key] = value
                end
                normalized_options[:fields] = normalized_fields

                normalized_options
            end

            # Array簡易形式を、フィールド名と同名のterms aggregationへ変換する。
            # Hash形式はElasticsearch形式としてそのまま使用する。
            def build_aggs(aggs_opts)
                return aggs_opts unless aggs_opts.instance_of?(Array)

                result = {}

                aggs_opts.each do |field_name|
                    result[field_name] = {
                        terms: {
                            field: field_name,
                            size:  DEFAULT_AGGS_SIZE,
                        },
                    }
                end

                result
            end
        end
    end
end
