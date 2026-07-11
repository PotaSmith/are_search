# frozen_string_literal: true

module AreSearch
    module SearchUtils
        ################################################################
        # fields
        ################################################################

        # combined_fields 用 fields の構造とフィールド名を確認する
        def validate_combined_fields_options!(fields_opts, valid_fields, caller_name:)
            if fields_opts.blank?
                raise ArgumentError,
                    "#{caller_name} :fields は必須です"
            end

            unless fields_opts.instance_of?(Array) || fields_opts.instance_of?(Hash)
                raise ArgumentError,
                    "#{caller_name} :fields は Array または Hash で指定してください: #{fields_opts.inspect}"
            end

            field_names = []
            if fields_opts.instance_of?(Hash)
                fields_opts.each_key do |field_name|
                    field_names << field_name
                end
            else
                fields_opts.each do |field_name|
                    field_names << field_name
                end
            end

            validate_option_field_names!(
                field_names,
                valid_fields,
                option_name: :fields,
                caller_name: caller_name,
            )
        end

        # More Like This 用 fields の構造とフィールド名を確認する
        def validate_mlt_fields_options!(fields_opts, valid_fields, caller_name:)
            if fields_opts.blank?
                raise ArgumentError,
                    "#{caller_name} :fields は必須です"
            end

            unless fields_opts.instance_of?(Array)
                raise ArgumentError,
                    "#{caller_name} :fields は Array で指定してください: #{fields_opts.inspect}"
            end

            validate_option_field_names!(
                fields_opts,
                valid_fields,
                option_name: :fields,
                caller_name: caller_name,
            )
        end

        # index_targets から検索オプションで指定可能なフィールド名を収集する
        def collect_valid_fields(index_targets)
            result = []

            index_targets.each do |index_target|
                mappings = index_target.are_search_es_mappings

                properties = mappings[:properties]
                if properties.instance_of?(Hash)
                    properties.each_key do |field_name|
                        result << field_name.to_s.to_sym
                    end
                end

                runtime_fields = mappings[:runtime]
                if runtime_fields.instance_of?(Hash)
                    runtime_fields.each_key do |field_name|
                        result << field_name.to_s.to_sym
                    end
                end
            end

            result.uniq
        end

        # 親切 typo チェック対象になるフィールド名だけを未定義チェックする
        def invalid_typo_checkable_fields(fields, valid_fields)
            invalid = []

            fields.each do |field|
                next unless field_name_typo_checkable?(field)

                field_name = field.to_s.to_sym
                next if valid_fields.include?(field_name)

                invalid << field_name
            end

            invalid.uniq
        end

        # 単純な小文字フィールド名を親切 typo チェック対象とする
        def field_name_typo_checkable?(field)
            field_text = field.to_s

            field_text.match?(/\A[a-z](?:[a-z0-9_]*[a-z0-9])?\z/)
        end

        # 指定されたオプション内のフィールド名に明らかな typo がないか確認する
        def validate_option_field_names!(field_names, valid_fields, option_name:, caller_name:)
            invalid = invalid_typo_checkable_fields(field_names, valid_fields)
            return if invalid.empty?

            raise ArgumentError,
                "#{caller_name} :#{option_name} に未定義のフィールドがあります: #{invalid.inspect}"
        end

        # combined_fields 用 fields を共通の field / boost 形式へ変換する
        def normalize_fields(fields_opts)
            if fields_opts.instance_of?(Hash)
                return fields_opts.map do |field_name, boost|
                    {
                        name:  field_name,
                        boost: boost,
                    }
                end
            end

            fields_opts.map do |field_name|
                {
                    name:  field_name,
                    boost: nil,
                }
            end
        end

        # More Like This 用 fields を body 構築用の配列へ変換する
        def normalize_mlt_fields(fields_opts)
            fields_opts.dup
        end

        # normalized_fields から combined_fields query を組み立てる
        def build_combined_fields_clause(query, normalized_fields)
            es_fields = []

            normalized_fields.each do |field|
                if field[:boost].nil?
                    es_fields << field[:name].to_s
                else
                    es_fields << "#{field[:name]}^#{field[:boost]}"
                end
            end

            {
                combined_fields: {
                    query:    query,
                    fields:   es_fields,
                    operator: "and",
                },
            }
        end

        ################################################################
        # sort
        ################################################################

        # sort の構造と通常フィールド名を確認する
        def validate_sort_options!(sort_opts, valid_fields, caller_name:)
            return if sort_opts.nil?

            sort_fields = []

            if sort_opts.instance_of?(String) || sort_opts.instance_of?(Symbol)
                sort_fields << sort_opts
            elsif sort_opts.instance_of?(Hash)
                sort_opts.each_key do |field_name|
                    sort_fields << field_name
                end
            elsif sort_opts.instance_of?(Array)
                sort_opts.each do |sort_entry|
                    if sort_entry.instance_of?(String) || sort_entry.instance_of?(Symbol)
                        sort_fields << sort_entry
                        next
                    end

                    unless sort_entry.instance_of?(Hash)
                        raise ArgumentError,
                            "#{caller_name} :sort の各要素はフィールド名または Hash で指定してください: #{sort_entry.inspect}"
                    end

                    sort_entry.each_key do |field_name|
                        sort_fields << field_name
                    end
                end
            else
                raise ArgumentError,
                    "#{caller_name} :sort はフィールド名、Hash、または Array で指定してください: #{sort_opts.inspect}"
            end

            validate_option_field_names!(
                sort_fields,
                valid_fields,
                option_name: :sort,
                caller_name: caller_name,
            )
        end

        ################################################################
        # where / where_not / where_or
        ################################################################

        # where / where_not / where_or の構造とフィールド名を確認する
        def validate_condition_options!(condition_opts, valid_fields, option_name:, caller_name:)
            return if condition_opts.nil?

            condition_fields = []

            if condition_opts.instance_of?(Hash)
                condition_opts.each_key do |field|
                    condition_fields << field
                end
            elsif condition_opts.instance_of?(Array)
                condition_opts.each do |condition_opt|
                    if condition_opt.instance_of?(Hash) == false
                        raise ArgumentError,
                            "#{caller_name} :#{option_name} の各要素は Hash で指定してください: #{condition_opt.inspect}"
                    end

                    field = condition_opt[:field]
                    if field.nil?
                        raise ArgumentError,
                            "#{caller_name} :#{option_name} の各要素には :field が必要です: #{condition_opt.inspect}"
                    end

                    if condition_opt.key?(:value) == false
                        raise ArgumentError,
                            "#{caller_name} :#{option_name} の各要素には :value が必要です: #{condition_opt.inspect}"
                    end

                    condition_fields << field
                end
            else
                raise ArgumentError,
                    "#{caller_name} :#{option_name} は Hash または Array<Hash> で指定してください: #{condition_opts.inspect}"
            end

            validate_option_field_names!(
                condition_fields,
                valid_fields,
                option_name: option_name,
                caller_name: caller_name,
            )
        end

        # Hash または Array<Hash> を共通の field / value / boost 条件へ変換する
        def normalize_condition_options(condition_opts)
            normalized_conditions = []
            return normalized_conditions if condition_opts.nil?

            if condition_opts.instance_of?(Hash)
                condition_opts.each do |field, value|
                    normalized_conditions << {
                        field: field,
                        value: value,
                        boost: nil,
                    }
                end

                return normalized_conditions
            end

            condition_opts.each do |condition_opt|
                normalized_conditions << {
                    field: condition_opt[:field],
                    value: condition_opt[:value],
                    boost: condition_opt[:boost],
                }
            end

            normalized_conditions
        end

        # 共通の field / value / boost 条件から ES の query 句配列を組み立てる
        def build_field_clauses(conditions)
            clauses = []

            conditions.each do |condition|
                clauses << build_field_clause(condition)
            end

            clauses
        end

        # 1件の field / value / boost 条件を term / terms / range のいずれかへ変換する
        def build_field_clause(condition)
            field = condition[:field]
            value = condition[:value]
            boost = condition[:boost]

            if value.instance_of?(Hash)
                range_value = value.dup
                range_value[:boost] = boost if boost.nil? == false

                return { range: { field => range_value } }
            end

            if value.instance_of?(Array)
                terms_value = { field => value }
                terms_value[:boost] = boost if boost.nil? == false

                return { terms: terms_value }
            end

            if boost.nil?
                return { term: { field => value } }
            end

            { term: { field => { value: value, boost: boost } } }
        end

        ################################################################
        # bool
        ################################################################

        # filter / must_not / should 節を持つ bool_clause のベースを組み立てる
        def build_bool_base(index_targets, filter_clauses, must_not_clauses, where_or_clauses)
            all_filter_clauses = filter_clauses.dup
            model_filter_clause = AreSearch::SearchBase.build_model_filter_clause(index_targets)
            all_filter_clauses << model_filter_clause

            bool_clause = {}
            bool_clause[:filter] = all_filter_clauses if all_filter_clauses.any?
            bool_clause[:must_not] = must_not_clauses if must_not_clauses.any?

            if where_or_clauses.any?
                bool_clause[:should] = where_or_clauses
                bool_clause[:minimum_should_match] = 1
            end

            bool_clause
        end

        ################################################################
        # aggs
        ################################################################

        # aggs の構造と集計対象フィールド名を確認する
        def validate_aggs_options!(aggs_opts, valid_fields, caller_name:)
            return if aggs_opts.nil?

            unless aggs_opts.instance_of?(Array)
                raise ArgumentError,
                    "#{caller_name} :aggs は Array で指定してください: #{aggs_opts.inspect}"
            end

            agg_fields = []

            aggs_opts.each do |entry|
                if entry.instance_of?(Hash)
                    entry.each do |field, terms_options|
                        unless terms_options.instance_of?(Hash)
                            raise ArgumentError,
                                "#{caller_name} :aggs の個別設定は Hash で指定してください: #{terms_options.inspect}"
                        end

                        agg_fields << field
                    end
                else
                    agg_fields << entry
                end
            end

            validate_option_field_names!(
                agg_fields,
                valid_fields,
                option_name: :aggs,
                caller_name: caller_name,
            )
        end

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

        ################################################################
        # highlight
        ################################################################

        # highlight の構造と対象フィールド名を確認する
        def validate_highlight_options!(highlight_opts, valid_fields, caller_name:)
            return if highlight_opts.nil?

            unless highlight_opts.instance_of?(Hash)
                raise ArgumentError,
                    "#{caller_name} :highlight は Hash で指定してください: #{highlight_opts.inspect}"
            end

            highlight_fields = highlight_opts[:fields]
            return if highlight_fields.nil?

            field_names = []

            if highlight_fields.instance_of?(Hash)
                highlight_fields.each_key do |field_name|
                    field_names << field_name
                end
            elsif highlight_fields.instance_of?(Array)
                highlight_fields.each do |field_entry|
                    if field_entry.instance_of?(Hash)
                        field_entry.each_key do |field_name|
                            field_names << field_name
                        end
                    else
                        field_names << field_entry
                    end
                end
            else
                raise ArgumentError,
                    "#{caller_name} :highlight の :fields は Hash または Array で指定してください: #{highlight_fields.inspect}"
            end

            validate_option_field_names!(
                field_names,
                valid_fields,
                option_name: :highlight,
                caller_name: caller_name,
            )
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
