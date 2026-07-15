# frozen_string_literal: true

module AreSearch
    class SearchOptionValidator
        class TypeNotFound; end

        class << self
            # 検索オプションまたは単一nodeを定義に従って検査し、正規化済みの値を返す。
            def validate(opts, definition, context)
                normalized_context = normalize_context(context)

                validate_options(
                    opts,
                    definition,
                    normalized_context,
                )
            end

            private

            # OPTION_DEFINITIONS全体を使い、検索オプションHashを検査して正規化する。
            def validate_options(opts, definitions, context)
                if opts.instance_of?(Hash) == false
                    raise ArgumentError,
                        "opts は Hash で指定してください: #{opts.inspect}"
                end

                normalized_options = {}

                opts.each do |raw_option_name, raw_value|
                    parse_symbol_value(raw_option_name, "opts[:#{raw_option_name}]")

                    if definitions[raw_option_name] == nil
                        raise ArgumentError,
                            "未知の検索オプションが指定されています: #{raw_option_name}"
                    end
                    # 上を通貨した時点で sym 確定
                    sym_option_name = raw_option_name

                    normalized_options[sym_option_name] = parse_node(
                        raw_value,
                        definitions[sym_option_name],
                        "opts[:#{sym_option_name}]",
                        context,
                    )
                end

                normalized_options
            end

            # nodeの実体型からscalar、Hash、Arrayの処理へ一度だけ分岐する。
            def parse_node(node, definitions, path, context)
                # 型強制があるか
                definition_type = definitions[:type]

                if definition_type != nil
                    return parse_definition_type(
                        node,
                        definition_type,
                        path,
                        context,
                    )
                end

                node_type = detect_node_type(node)
                definition = definitions[node_type]

                if definition.nil?
                    raise ArgumentError,
                        "#{path} のnode_type #{node_type.inspect} は定義されていません: #{node.inspect}"
                end

                if node_type == :scalar
                    parse_scalar(node, definition, path, context)
                elsif node_type == :array
                    parse_array(node, definition, path, context)
                elsif node_type == :hash
                    parse_hash(node, definition, path, context)
                else
                    raise ArgumentError,
                        "未知のnode_typeです: #{node_type.inspect}"
                end
            end

            # 入力値を再帰処理で使用するnode_typeへ分類する。
            def detect_node_type(node)
                return :hash if node.instance_of?(Hash)
                return :array if node.instance_of?(Array)

                :scalar
            end

            # scalar nodeを共通のtype定義で検査して正規化する。
            def parse_scalar(value, definition, path, context)
                parse_definition_type(
                    value,
                    definition[:type],
                    path,
                    context,
                )
            end

            # Arrayの各要素を共通の子node定義と組み合わせて再帰検査する。
            def parse_array(array_node, definition, path, context)
                if array_node.empty? && definition[:allow_empty] != true
                    raise ArgumentError, "#{path} は1件以上指定してください"
                end

                normalized_array = []

                array_node.each_with_index do |child_node, index|
                    normalized_array << parse_node(
                        child_node,
                        definition[:children],
                        "#{path}[#{index}]",
                        context,
                    )
                end

                normalized_array
            end

            # Hash固有条件を確認し、keyでentryを選択してvalueを再帰検査する。
            def parse_hash(hash_node, definition, path, context)
                if hash_node.empty? && definition[:allow_empty] != true
                    raise ArgumentError, "#{path} は1件以上指定してください"
                end

                normalized_hash = {}

                hash_node.each do |raw_key, raw_value|
                    selected_value_definition = select_hash_entry(
                        raw_key,
                        definition[:key_values],
                        path,
                        context,
                    )

                    if selected_value_definition == nil
                        raise ArgumentError,
                            "#{path} に未知のキーがあります: #{raw_key}"
                    end

                    normalized_hash[raw_key] = parse_node(
                        raw_value,
                        selected_value_definition,
                        "#{path}[#{raw_key}]",
                        context,
                    )
                end

                validate_hash_item_count(normalized_hash, definition, path)
                validate_must_not_keys(normalized_hash, definition, path)
                validate_must_keys(normalized_hash, definition, path)

                normalized_hash
            end

            # Hashキーに完全一致するkey_name定義を優先し、なければtype定義から選択する。
            def select_hash_entry(raw_key, key_values_definitions, path, context)

                # 上からキーの名前で探索して最初にヒットしたものを返す
                key_values_definitions.each do |key_values_definition|
                    key_definition = key_values_definition[:key]
                    next if key_definition.nil?
                    next if key_definition[:key_name].nil?

                    # sym じゃないものはヒットしない
                    if key_definition[:key_name] == raw_key
                        return key_values_definition[:value]
                    end
                end

                # 上からキーの型で探索して最初にヒットしたものを返す
                key_values_definitions.each do |key_values_definition|
                    key_definition = key_values_definition[:key]
                    next if key_definition.nil?
                    next if key_definition[:type].nil?

                    begin
                        # 型チェックに通るかの確認
                        parse_definition_type(
                            raw_key,
                            key_definition[:type],
                            "#{path} のキー",
                            context,
                        )

                        # チェックにパスしたらそれ
                        return key_values_definition[:value]
                    rescue ArgumentError
                        next
                    end
                end

                return nil
            end

            # Hashの要素数がitem_countと一致することを確認する。
            def validate_hash_item_count(normalized_hash, definition, path)
                return if definition.key?(:item_count) == false
                return if normalized_hash.length == definition[:item_count]

                raise ArgumentError,
                    "#{path} は #{definition[:item_count]} 件で指定してください: #{normalized_hash.inspect}"
            end

            # must_keysに指定された固定キーがHash内に存在することを確認する。
            def validate_must_keys(normalized_hash, definition, path)
                return if definition.key?(:must_keys) == false

                missing_keys = definition[:must_keys] - normalized_hash.keys
                return if missing_keys.empty?

                raise ArgumentError,
                    "#{path} に必要なキーがありません: #{missing_keys.inspect}"
            end

            # must_not_keysに指定された固定キーがHash内に存在しないことを確認する。
            def validate_must_not_keys(normalized_hash, definition, path)
                return if definition.key?(:must_not_keys) == false

                prohibited_keys = definition[:must_not_keys] & normalized_hash.keys
                return if prohibited_keys.empty?

                raise ArgumentError,
                    "#{path} に指定できないキーがあります: #{prohibited_keys.inspect}"
            end

            # 名前付きtypeに従って単一値を検査し、正規化する。
            def parse_definition_type(value, type, path, context)
                case type
                when "any"
                    parse_any_value(value)
                when "string"
                    parse_string_value(value, path)
                when "not_nil"
                    parse_not_nil_value(value, path)
                when "boolean"
                    parse_boolean_value(value, path)
                when "str_or_sym"
                    parse_str_or_sym_value(value, path)
                when "str_or_int"
                    parse_str_or_int_value(value, path)
                when "str_or_int_or_bool"
                    parse_str_or_int_or_bool_value(value, path)
                when "positive_number"
                    parse_positive_number(value, path)
                when "positive_integer"
                    parse_positive_integer(value, path)
                when "symbol_key"
                    parse_symbol_key(value, path)
                when "sort_field"
                    parse_sort_field(value, context, path)
                when "model_class"
                    parse_model_class(value, path)
                when "valid_model"
                    parse_context_field(value, context, :models, path)
                when "any_valid_field"
                    parse_named_context_field(value, context, :any_fields, path)
                when "all_valid_field"
                    parse_named_context_field(value, context, :all_fields, path)
                when "any_text_without_non_text_field"
                    parse_named_context_field(value, context, :any_text_without_non_text_fields, path)
                when "all_valid_text_field"
                    parse_named_context_field(value, context, :all_valid_text_fields, path)
                when "any_text_or_keyword_without_other_type_field"
                    parse_named_context_field(value, context, :any_text_or_keyword_without_other_type_fields, path)
                when "all_valid_text_or_keyword_field"
                    parse_named_context_field(value, context, :all_valid_text_or_keyword_fields, path)
                when "any_non_text_without_text_field"
                    parse_named_context_field(value, context, :any_non_text_without_text_fields, path)
                when "all_valid_non_text_field"
                    parse_named_context_field(value, context, :all_valid_non_text_fields, path)
                when "searchable_instance"
                    parse_searchable_instance(value, path)
                when "index_target"
                    parse_index_target(value, path)
                else
                    raise ArgumentError, "未知の type です: #{type.inspect}"
                end
            end

            # 入力を変更しないため、HashとArrayだけを再帰的に複製する。
            def parse_any_value(value)
                if value.instance_of?(Hash)
                    copied_hash = {}

                    value.each do |key, child_value|
                        copied_hash[key] = parse_any_value(child_value)
                    end

                    return copied_hash
                end

                if value.instance_of?(Array)
                    copied_array = []

                    value.each do |child_value|
                        copied_array << parse_any_value(child_value)
                    end

                    return copied_array
                end

                value
            end

            # Symbolだけを許可する。
            def parse_symbol_value(value, path)
                if value.instance_of?(Symbol) == false
                    raise ArgumentError,
                        "#{path} は Symbol で指定してください: #{value.inspect}"
                end

                value
            end

            # Stringだけを許可する。
            def parse_string_value(value, path)
                if value.instance_of?(String) == false
                    raise ArgumentError,
                        "#{path} は String で指定してください: #{value.inspect}"
                end

                value
            end

            # 値の型は限定せず、nilだけを拒否して入力とは別の値を返す。
            def parse_not_nil_value(value, path)
                if value.nil?
                    raise ArgumentError,
                        "#{path} に nil は指定できません"
                end

                parse_any_value(value)
            end

            # boolean型としてtrueまたはfalseだけを許可する。
            def parse_boolean_value(value, path)
                return value if value == true
                return value if value == false

                raise ArgumentError,
                    "#{path} は true または false で指定してください: #{value.inspect}"
            end

            # StringまたはSymbolの単一値だけを許可する。
            def parse_str_or_sym_value(value, path)
                return value if value.instance_of?(String)
                return value if value.instance_of?(Symbol)

                raise ArgumentError,
                    "#{path} は String または Symbol で指定してください: #{value.inspect}"
            end

            # StringまたはIntegerの単一値だけを許可する。
            def parse_str_or_int_value(value, path)
                return value if value.instance_of?(String)
                return value if value.instance_of?(Integer)

                raise ArgumentError,
                    "#{path} は String または Integer で指定してください: #{value.inspect}"
            end

            # String、Integer、true、falseの単一値だけを許可する。
            def parse_str_or_int_or_bool_value(value, path)
                return value if value.instance_of?(String)
                return value if value.instance_of?(Integer)
                return value if value == true
                return value if value == false

                raise ArgumentError,
                    "#{path} は String、Integer、true、falseのいずれかで指定してください: #{value.inspect}"
            end

            # 正のIntegerまたはFloatだけを許可する。
            def parse_positive_number(value, path)
                numeric = value.instance_of?(Integer) || value.instance_of?(Float)

                if numeric && value > 0
                    return value
                end

                raise ArgumentError,
                    "#{path} は正の数で指定してください: #{value.inspect}"
            end

            # 正のIntegerだけを許可する。
            def parse_positive_integer(value, path)
                if value.instance_of?(Integer) && value > 0
                    return value
                end

                raise ArgumentError,
                    "#{path} は正の整数で指定してください: #{value.inspect}"
            end

            # sym key かどうか確認
            def parse_symbol_key(value, path)
                if value.instance_of?(Symbol) == false
                    raise ArgumentError,
                        "#{path} は symで指定してください: #{value.inspect}"
                end

                if value.match?(/\A[a-z]([a-z0-9_]*[a-z0-9])?\z/) == false
                    raise ArgumentError,
                        "#{path} は小文字英字で始まり、小文字英数字とアンダーバーを使用し、" \
                        "小文字英数字で終わる Symbol で指定してください: #{value.inspect}"
                end

                value
            end

            # sort対象フィールドチェック
            def parse_sort_field(value, context, path)
                return value if value == :_score
                return value if value == :_doc

                parse_context_field(
                    value,
                    context,
                    :all_valid_non_text_fields,
                    path,
                )
            end

            # モデル指定としてClassだけを許可する。
            def parse_model_class(value, path)
                return value if value.instance_of?(Class)

                raise ArgumentError,
                    "#{path} はモデルClassで指定してください: #{value.inspect}"
            end

            # フィールド名を指定されたcontextのフィールド一覧と照合する。
            def parse_context_field(field_name, context, context_key, path)
                if context.nil? || context[context_key].nil?
                    raise ArgumentError,
                        "#{path} の検査には context[:#{context_key}] が必要です"
                end

                return field_name if context[context_key].include?(field_name)

                raise ArgumentError,
                    "#{path} に context[:#{context_key}] に含まれないフィールドが指定されています: " \
                    "#{field_name.inspect}"
            end

            # context参照型のフィールド名を指定集合と照合する。
            def parse_named_context_field(value, context, context_key, path)
                parse_context_field(
                    value,
                    context,
                    context_key,
                    path,
                )
            end

            # Searchableをincludeしたインスタンスだけを許可する。
            def parse_searchable_instance(value, path)
                return value if value.class.include?(AreSearch::Searchable)

                raise ArgumentError,
                    "#{path} は AreSearch::Searchable のインスタンスで指定してください: #{value.inspect}"
            end

            # IndexTargetのインスタンスだけを許可する。
            def parse_index_target(value, path)
                return value if value.instance_of?(AreSearch::IndexTarget)

                raise ArgumentError,
                    "#{path} は AreSearch::IndexTarget で指定してください: #{value.inspect}"
            end

            ##############################################################
            # context 初期化
            ##############################################################

            # SearchOptionValidator外で収集した検索対象情報を検査用に正規化する。
            def normalize_context(context)
                return nil if context.nil?

                if context.instance_of?(Hash) == false
                    raise ArgumentError,
                        "context は Hash で指定してください: #{context.inspect}"
                end

                context_keys = [
                    :models,
                    :any_fields,
                    :all_fields,
                    :any_text_without_non_text_fields,
                    :all_valid_text_fields,
                    :any_text_or_keyword_without_other_type_fields,
                    :all_valid_text_or_keyword_fields,
                    :any_non_text_without_text_fields,
                    :all_valid_non_text_fields,
                ]
                missing_keys = context_keys - context.keys
                unknown_keys = context.keys - context_keys

                if missing_keys.empty? == false
                    raise ArgumentError,
                        "context に必要なキーがありません: #{missing_keys.inspect}"
                end

                if unknown_keys.empty? == false
                    raise ArgumentError,
                        "context に未知のキーがあります: #{unknown_keys.inspect}"
                end

                normalized_context = {
                    models: normalize_context_models(context[:models]),
                }

                context_keys.each do |context_key|
                    next if context_key == :models

                    normalized_context[context_key] = normalize_context_fields(
                        context[context_key],
                        "context[:#{context_key}]",
                    )
                end

                normalized_context
            end

            # contextのモデル一覧がClassのArrayであることを確認して複製する。
            def normalize_context_models(models)
                if models.instance_of?(Array) == false
                    raise ArgumentError,
                        "context[:models] は Array で指定してください: #{models.inspect}"
                end

                normalized_models = []

                models.each do |model|
                    if model.instance_of?(Class) == false
                        raise ArgumentError,
                            "context[:models] はモデルClassのArrayで指定してください: #{model.inspect}"
                    end

                    normalized_models << model
                end

                normalized_models.uniq
            end

            # contextのフィールド一覧をSymbolへ統一する。
            def normalize_context_fields(fields, path)
                if fields.instance_of?(Array) == false
                    raise ArgumentError,
                        "#{path} は Array で指定してください: #{fields.inspect}"
                end

                normalized_fields = []

                fields.each do |field|
                    unless field.instance_of?(String) || field.instance_of?(Symbol)
                        raise ArgumentError,
                            "#{path} は String または Symbol のArrayで指定してください: #{field.inspect}"
                    end

                    normalized_fields << field.to_sym
                end

                normalized_fields.uniq
            end
        end
    end
end
