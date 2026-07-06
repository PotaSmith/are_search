# frozen_string_literal: true

module AreSearch
    module SearchUtils
        ################################################################
        # fields
        ################################################################

        def require_fields!(fields, caller_name:)
            return unless fields.blank?

            raise ArgumentError,
                "#{caller_name} :fields は必須です"
        end

        # index_targets から有効なフィールド名の一覧を収集する
        def collect_valid_fields(index_targets)
            result = []
            index_targets.each do |index_target|
                keys = index_target.are_search_es_mappings.dig(:properties)&.keys&.map(&:to_sym) || []
                result += keys
            end
            result.uniq
        end

        # AreSearch の親切 typo チェック対象になる field 名だけを未定義チェックする。
        # _ 始まり、_ 終わり、ドット付き、大文字混じりは ES 側に判断を委ねる。
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

        def field_name_typo_checkable?(field)
            field_text = field.to_s

            field_text.match?(/\A[a-z](?:[a-z0-9_]*[a-z0-9])?\z/)
        end

        # fields を Hash / Array どちらで渡されても [{name:, boost:}] 形式に正規化する
        def normalize_fields(fields)
            case fields
            when Hash
                fields.map { |name, boost| { name: name.to_sym, boost: boost } }
            when Array
                fields.map { |field| { name: field.to_sym, boost: nil } }
            else
                raise ArgumentError,
                    "fields にはHashかArrayを指定して下さい: #{fields.inspect}"
            end
        end

        # --- 共通バリデーション（各メソッドがctxに積む） ---

        # normalized_fields のフィールド名が valid_fields に存在するか、
        # combined_fields の要件として text 型かをチェックし、ctxに積む
        def validate_combined_fields!(ctx, normalized_fields, index_targets, valid_fields, caller_name:)
            return if normalized_fields.blank?

            field_names = normalized_fields.map { |f| f[:name] }

            invalid = field_names - valid_fields
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :fields に未定義のフィールドがあります: #{invalid.inspect}"
            end

            non_text = field_names.reject do |field_name|
                field_defs = []
                index_targets.each do |index_target|
                    defn = index_target.are_search_es_mappings.dig(:properties, field_name)
                    field_defs << defn unless defn.nil?
                end
                field_defs.any? && field_defs.all? { |field_def| field_def[:type].to_s == "text" }
            end

            if non_text.any?
                raise ArgumentError,
                    "#{caller_name} :fields には text 型のフィールドのみ指定できます: #{non_text.inspect}"
            end

            ctx[:normalized_fields] = normalized_fields
        end

        # boost値が数値かつ1.0以上かチェック（ctxへの追記なし。validate_combined_fields!の後に呼ぶこと）
        def validate_boost!(normalized_fields, caller_name:)
            non_numeric = normalized_fields.select { |f| f[:boost] && ![Integer, Float].include?(f[:boost].class) }
            if non_numeric.any?
                details = non_numeric.map { |f| "#{f[:name]} : #{f[:boost]}" }.inspect
                raise ArgumentError, "#{caller_name} :fields の boost は数値で指定してください: #{details}"
            end

            too_small = normalized_fields.select { |f| f[:boost] && f[:boost] < 1.0 }
            if too_small.any?
                details = too_small.map { |f| "#{f[:name]} : #{f[:boost]}" }.inspect
                raise ArgumentError, "#{caller_name} :fields の boost は1.0以上で指定してください: #{details}"
            end
        end

        ################################################################
        # sort
        ################################################################

        # sort のフィールド名が typo チェック対象なら valid_fields に存在するか確認し、ctxに積む
        def validate_sort!(ctx, sort_opts, valid_fields, caller_name:)
            return if sort_opts.blank?

            sort_fields = []
            if sort_opts.instance_of?(Array)
                sort_opts.each do |h|
                    sort_fields += h.keys
                end
            else
                sort_fields = sort_opts.keys
            end

            invalid_sorts = invalid_typo_checkable_fields(sort_fields, valid_fields)
            if invalid_sorts.any?
                raise ArgumentError,
                    "#{caller_name} :sort に未定義のフィールドがあります: #{invalid_sorts.inspect}"
            end
            ctx[:sort] = sort_opts
        end

        ################################################################
        # where / where_not
        ################################################################

        # where条件をbuild_term_clausesでclausesに変換し、ctxに積む
        def validate_where!(ctx, where_opts, valid_fields, caller_name:)
            return if where_opts.blank?

            invalid = invalid_typo_checkable_fields(where_opts.keys, valid_fields)
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :where に未定義のフィールドがあります: #{invalid.inspect}"
            end
            ctx[:filter_clauses] = build_term_clauses(where_opts)
        end

        # where_not条件をbuild_term_clausesでclausesに変換し、ctxに積む
        def validate_where_not!(ctx, where_not_opts, valid_fields, caller_name:)
            return if where_not_opts.blank?

            invalid = invalid_typo_checkable_fields(where_not_opts.keys, valid_fields)
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :where_not に未定義のフィールドがあります: #{invalid.inspect}"
            end
            ctx[:must_not_clauses] = build_term_clauses(where_not_opts)
        end

        # where / where_not 用の term / terms 節を構築する
        def build_term_clauses(conditions)
            conditions.map do |field, value|
                case value
                when Hash
                    { range: { field => value } }
                when Array
                    { terms: { field => value } }
                else
                    { term: { field => value } }
                end
            end
        end

        ################################################################
        # should
        ################################################################

        # should条件・minimum_should_matchをチェックし、ctxに積む
        #
        # should_opts は Array<Hash>。各要素は :field（必須）, :value（必須）, :boost（任意）を持つ。
        # minimum_should_match_opts は Integer（0以上）。未指定時は 1。
        def validate_should!(ctx, should_opts, minimum_should_match_opts, valid_fields, caller_name:)
            validate_minimum_should_match!(ctx, minimum_should_match_opts, caller_name: caller_name)

            return if should_opts.blank?

            unless should_opts.instance_of?(Array)
                raise ArgumentError,
                    "#{caller_name} :should は Array<Hash> で指定してください: #{should_opts.inspect}"
            end

            should_opts.each do |clause|
                validate_should_clause!(clause, valid_fields, caller_name: caller_name)
            end

            ctx[:should_clauses] = build_should_clauses(should_opts)
        end

        def validate_should_clause!(clause, valid_fields, caller_name:)
            unless clause.instance_of?(Hash)
                raise ArgumentError,
                    "#{caller_name} :should の各要素は Hash で指定してください: #{clause.inspect}"
            end

            field = clause[:field]
            if field.nil?
                raise ArgumentError,
                    "#{caller_name} :should の各要素には :field が必要です: #{clause.inspect}"
            end

            unless clause.key?(:value)
                raise ArgumentError,
                    "#{caller_name} :should の各要素には :value が必要です: #{clause.inspect}"
            end

            invalid = invalid_typo_checkable_fields([field], valid_fields)
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :should に未定義のフィールドがあります: #{field.inspect}"
            end

            validate_should_boost!(clause, caller_name: caller_name)
            validate_should_range_boost!(clause, caller_name: caller_name)
        end

        # should の1要素の :boost をチェックする（型: Integer/Float、値: 0以上）
        def validate_should_boost!(clause, caller_name:)
            boost = clause[:boost]
            return if boost.nil?

            unless [Integer, Float].include?(boost.class)
                raise ArgumentError,
                    "#{caller_name} :should の boost は数値で指定してください: #{clause[:field]} : #{boost}"
            end

            if boost < 0
                raise ArgumentError,
                    "#{caller_name} :should の boost は0以上で指定してください: #{clause[:field]} : #{boost}"
            end
        end

        def validate_should_range_boost!(clause, caller_name:)
            value = clause[:value]
            return unless value.instance_of?(Hash)
            return unless value.key?(:boost)

            raise ArgumentError,
                "#{caller_name} :should の range value 内に boost は指定できません。boost: は should 要素の直下に指定してください: #{clause.inspect}"
        end

        # minimum_should_match をチェックし、ctxに積む（Integer、0以上、未指定時は1）
        def validate_minimum_should_match!(ctx, minimum_should_match_opts, caller_name:)
            if minimum_should_match_opts.nil?
                ctx[:minimum_should_match] = 1
                return
            end

            unless minimum_should_match_opts.instance_of?(Integer) && minimum_should_match_opts >= 0
                raise ArgumentError,
                    "#{caller_name} :minimum_should_match は0以上の整数で指定してください: #{minimum_should_match_opts.inspect}"
            end

            ctx[:minimum_should_match] = minimum_should_match_opts
        end

        # --- body 組み立てヘルパー ---

        # should_opts から ES リクエスト用の should 句配列を組み立てる
        #
        # 各要素の :value の型に応じて term / terms / range に振り分け、:boost を埋め込む。
        # :boost 未指定時は 1.0 を補完する。
        def build_should_clauses(should_opts)
            should_opts.map do |clause|
                field = clause[:field]
                value = clause[:value]
                boost = clause[:boost] || 1.0

                case value
                when Hash
                    range_value = value.merge(boost: boost)
                    { range: { field => range_value } }
                when Array
                    { terms: { field => value, boost: boost } }
                else
                    { term: { field => { value: value, boost: boost } } }
                end
            end
        end

        ################################################################
        # bool
        ################################################################

        # filter / must_not / should 節を持つ bool_clause のベースを組み立てる
        def build_bool_base(filter_clauses, must_not_clauses, should_clauses, minimum_should_match)
            bool_clause = {}
            bool_clause[:filter]   = filter_clauses   if filter_clauses.any?
            bool_clause[:must_not] = must_not_clauses if must_not_clauses.any?
            if should_clauses.any?
                bool_clause[:should]               = should_clauses
                bool_clause[:minimum_should_match] = minimum_should_match
            end
            bool_clause
        end

        ################################################################
        # aggs
        ################################################################

        # aggs_fields のフィールド名が valid_fields に存在するかチェックし、ctxに積む
        def validate_aggs!(ctx, aggs_opts, valid_fields, caller_name:)
            return if aggs_opts.blank?

            unless aggs_opts.instance_of?(Array)
                raise ArgumentError,
                    "#{caller_name} :aggs は Array で指定してください: #{aggs_opts.inspect}"
            end

            normalized_aggs = normalize_aggs(aggs_opts)
            fields = normalized_aggs.map { |agg| agg[:field] }

            invalid = invalid_typo_checkable_fields(fields, valid_fields)
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :aggs に未定義のフィールドがあります: #{invalid.inspect}"
            end

            ctx[:aggs_fields] = normalized_aggs
        end

        def normalize_aggs(aggs_opts)
            result = []

            aggs_opts.each do |entry|
                if entry.instance_of?(Hash)
                    entry.each do |field, terms_options|
                        unless terms_options.instance_of?(Hash)
                            raise ArgumentError, ":aggs の個別設定は Hash で指定してください: #{terms_options.inspect}"
                        end

                        result << {
                            field:         field.to_sym,
                            terms_options: { size: AreSearch.default_aggs_size }.merge(terms_options)
                        }
                    end
                else
                    result << {
                        field:         entry.to_sym,
                        terms_options: { size: AreSearch.default_aggs_size },
                    }
                end
            end

            result
        end

        # aggs_fields から ES リクエスト用の aggs ハッシュを組み立てる
        def build_aggs(aggs_fields)
            result = {}

            aggs_fields.each do |agg|
                field = agg[:field]
                terms_options = agg[:terms_options].merge(field: field)

                result[field] = { terms: terms_options }
            end

            result
        end

        ################################################################
        # highlight
        ################################################################

        # highlight オプションのフィールド名チェックをし、highlight_fields をctxに積む
        # default_fields: highlight :fields 未指定時のデフォルト (Array<Symbol>)
        def validate_highlight!(ctx, highlight_opts, default_fields, valid_fields, caller_name:)
            return if highlight_opts.nil?

            unless highlight_opts.is_a?(Hash)
                raise ArgumentError,
                    "#{caller_name} :highlight は Hash で指定してください: #{highlight_opts.inspect}"
            end

            raw = highlight_opts.fetch(:fields, default_fields)

            unless raw.instance_of?(Array)
                raise ArgumentError,
                    "#{caller_name} :highlight の :fields は Array<Symbol> で指定してください: #{raw.inspect}"
            end

            highlight_fields = raw.map(&:to_sym)

            invalid = invalid_typo_checkable_fields(highlight_fields, valid_fields)
            if invalid.any?
                raise ArgumentError,
                    "#{caller_name} :highlight の :fields に未定義のフィールドがあります: #{invalid.inspect}"
            end
            ctx[:highlight_fields] = highlight_fields
        end

        # highlight_fields と highlight_opts から ES リクエスト用の highlight ボディを組み立てる
        def build_highlight_body(highlight_fields, highlight_opts)
            fields = {}
            highlight_fields.each do |f|
                fields[f] = {}
            end
            body = { fields: fields }
            body[:fragment_size] = highlight_opts[:fragment_size] if highlight_opts[:fragment_size]
            body[:pre_tags]      = AreSearch::SearchResult::HIGHLIGHT_PRE_TAGS
            body[:post_tags]     = AreSearch::SearchResult::HIGHLIGHT_POST_TAGS
            body[:encoder]       = "html"
            body
        end
    end
end
