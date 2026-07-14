# frozen_string_literal: true

module AreSearch
    class SearchOptionValidator

        # SearchOptionValidator が解釈できる定義ノードのキー。
        ITEM_DEFINITION_KEYS = [
            :key_name,
            :key_type,
            :item_type,
            :item_count,
            :allow_empty,
            :items,
            :must_keys,
            :must_not_keys,
        ].freeze

        # validate_named_item_type が処理できる名前付き item_type。
        NAMED_ITEM_TYPES = [
            "any",
            "not_nil",
            "boolean",
            "str_or_sym",
            "str_or_int",
            "str_or_int_or_bool",
            "positive_number",
            "positive_integer",
            "search_field",
            "sort_field",
            "any_valid_search_field",
            "all_valid_search_field",
            "any_valid_text_search_field",
            "all_valid_text_search_field",
            "field_name",
            "any_valid_field",
            "all_valid_field",
            "any_valid_text_field",
            "all_valid_text_field",
            "any_valid_text_or_keyword_field",
            "all_valid_text_or_keyword_field",
            "any_valid_non_text_field",
            "all_valid_non_text_field",
            "model_class",
            "valid_model",
            "searchable_instance",
            "index_target",
        ].freeze

        # normalize_key_type が処理できる名前付き key_type。
        NAMED_KEY_TYPES = [
            "symbol_key",
            "field_name",
            "sort_field",
            "any_valid_field",
            "all_valid_field",
            "any_valid_text_field",
            "all_valid_text_field",
            "any_valid_text_or_keyword_field",
            "all_valid_text_or_keyword_field",
            "any_valid_non_text_field",
            "all_valid_non_text_field",
            "model_class",
            "valid_model",
        ].freeze

        class DefinitionMismatch < StandardError; end
        private_constant :DefinitionMismatch

        class << self

            # 検索オプションまたは単一値を定義に従って検査し、
            # 入力を変更せず正規化済みの値を返す。
            def validate(opts, definition, context: nil)
                normalized_context = normalize_context(context)

                begin
                    if option_definition_map?(definition)
                        return validate_options(
                            opts,
                            definition,
                            normalized_context,
                        )
                    end

                    if definition.instance_of?(Array)
                        return validate_definition_candidates(
                            opts,
                            definition,
                            "opts",
                            context: normalized_context,
                        )
                    end

                    validate_definition_node(
                        opts,
                        definition,
                        "opts",
                        context: normalized_context,
                    )
                rescue DefinitionMismatch => e
                    raise ArgumentError, e.message
                end
            end

            private

            # definition が OPTION_DEFINITIONS 全体か、単一定義ノードかを判定する。
            def option_definition_map?(definition)
                return false unless definition.instance_of?(Hash)
                return false if definition.key?(:item_type)

                true
            end

            # OPTION_DEFINITIONS 全体を使い、検索オプションHashを検査して正規化する。
            def validate_options(opts, definitions, context)
                unless opts.instance_of?(Hash)
                    raise DefinitionMismatch,
                        "opts は Hash で指定してください: #{opts.inspect}"
                end

                normalized_options = {}

                opts.each do |raw_option_name, raw_value|
                    option_name = normalize_symbol_key(
                        raw_option_name,
                        "opts のオプション名",
                    )

                    unless definitions.key?(option_name)
                        raise DefinitionMismatch,
                            "未知の検索オプションが指定されています: #{option_name.inspect}"
                    end

                    if normalized_options.key?(option_name)
                        raise DefinitionMismatch,
                            "同じ検索オプションが重複しています: #{option_name.inspect}"
                    end

                    if raw_value.nil?
                        normalized_options[option_name] = nil
                        next
                    end

                    normalized_value = validate_definition_candidates(
                        raw_value,
                        definitions[option_name],
                        "opts[:#{option_name}]",
                        context: context,
                    )

                    normalized_options[option_name] = normalize_option_value(
                        option_name,
                        normalized_value,
                        "opts[:#{option_name}]",
                    )
                end

                normalized_options
            end

            # SearchOptionValidator外で収集した検索対象情報を検査用に正規化する。
            #
            # any_fields / all_fields は、フィールドが存在するtargetの範囲を表す。
            # any_valid_* は、未定義targetを許容しつつ、同名フィールドの型混在を除外した集合。
            # all_valid_* は、すべてのtargetで指定型として定義されているフィールドの集合。
            #
            # context未指定時は定義単体の検査だけを行う。
            def normalize_context(context)
                return nil if context.nil?

                unless context.instance_of?(Hash)
                    raise ArgumentError,
                        "context は Hash で指定してください: #{context.inspect}"
                end

                context_keys = [
                    :models,
                    :any_fields,
                    :all_fields,
                    :any_valid_text_fields,
                    :all_valid_text_fields,
                    :any_valid_text_or_keyword_fields,
                    :all_valid_text_or_keyword_fields,
                    :any_valid_non_text_fields,
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
                unless models.instance_of?(Array)
                    raise ArgumentError,
                        "context[:models] は Array で指定してください: #{models.inspect}"
                end

                normalized_models = []

                models.each do |model|
                    unless model.instance_of?(Class)
                        raise ArgumentError,
                            "context[:models] はモデルClassのArrayで指定してください: #{model.inspect}"
                    end

                    normalized_models << model
                end

                normalized_models.uniq
            end

            # contextのフィールド一覧をSymbolへ統一する。
            def normalize_context_fields(fields, path)
                unless fields.instance_of?(Array)
                    raise ArgumentError,
                        "#{path} は Array で指定してください: #{fields.inspect}"
                end

                normalized_fields = []

                fields.each do |field|
                    normalized_fields << normalize_field_name(field, path)
                end

                normalized_fields.uniq
            end

            # contextの指定キーから正規化済み一覧を取得する。
            def context_values(context, context_key, path)
                if context.nil?
                    raise ArgumentError,
                        "#{path} の検査には context[:#{context_key}] が必要です"
                end

                context[context_key]
            end

            # フィールド名を指定されたcontextのフィールド一覧と照合する。
            # 表記による例外は設けず、valid系の型は必ず定義済みフィールドだけを許可する。
            def validate_context_field(field_name, context, context_key, path)
                valid_fields = context_values(
                    context,
                    context_key,
                    path,
                )

                return field_name if valid_fields.include?(field_name)

                raise DefinitionMismatch,
                    "#{path} に context[:#{context_key}] に含まれないフィールドが指定されています: " \
                    "#{field_name.inspect}"
            end

            # boost付き検索フィールドのfieldを指定されたcontextの一覧と照合する。
            def validate_context_search_field(search_field, context, context_key, path)
                validate_context_field(
                    search_field[:field],
                    context,
                    context_key,
                    path,
                )

                search_field
            end

            # モデルClassをcontext[:models]と照合する。
            def validate_context_model(model, context, path)
                models = context_values(
                    context,
                    :models,
                    path,
                )

                return model if models.include?(model)

                model_name = model.name
                model_name = model.inspect if model_name.nil?

                raise DefinitionMismatch,
                    "#{path} のモデルは context[:models] に含まれていません: #{model_name}"
            end

            # 候補定義を順番に試し、最初に一致した定義の正規化結果を返す。
            def validate_definition_candidates(value, definitions, path, context:)
                unless definitions.instance_of?(Array) && definitions.empty? == false
                    raise ArgumentError,
                        "#{path} の定義は1件以上の Array で指定してください"
                end

                mismatch_messages = []

                definitions.each_with_index do |definition, index|
                    begin
                        return validate_definition_node(
                            value,
                            definition,
                            path,
                            context: context,
                        )
                    rescue DefinitionMismatch => e
                        mismatch_messages << "候補#{index}: #{e.message}"
                    end
                end

                raise DefinitionMismatch,
                    "#{path} が定義に一致しません: #{mismatch_messages.join(' / ')}"
            end

            # 1件の定義ノードに従って値を検査し、正規化結果を返す。
            def validate_definition_node(value, definition, path, context:)
                unless definition.instance_of?(Hash)
                    raise ArgumentError,
                        "#{path} の定義は Hash で指定してください: #{definition.inspect}"
                end

                unless definition.key?(:item_type)
                    raise ArgumentError,
                        "#{path} の定義に :item_type がありません"
                end

                item_type = definition[:item_type]

                if item_type == Array
                    return validate_array_value(
                        value,
                        definition,
                        path,
                        context: context,
                    )
                end

                if item_type == Hash
                    return validate_hash_value(
                        value,
                        definition,
                        path,
                        context: context,
                    )
                end

                validate_scalar_value(
                    value,
                    item_type,
                    path,
                    context: context,
                )
            end

            # Arrayを検査し、各要素を候補定義に従って正規化する。
            def validate_array_value(value, definition, path, context:)
                unless value.instance_of?(Array)
                    raise DefinitionMismatch,
                        "#{path} は Array で指定してください: #{value.inspect}"
                end

                if value.empty? && definition[:allow_empty] != true
                    raise DefinitionMismatch,
                        "#{path} は1件以上指定してください"
                end

                unless definition.key?(:items)
                    return deep_copy_value(value)
                end

                item_definitions = definition[:items]
                unless item_definitions.instance_of?(Array)
                    raise ArgumentError,
                        "#{path} の Array用 :items は Array で指定してください"
                end

                normalized_values = []

                value.each_with_index do |item_value, index|
                    normalized_values << validate_definition_candidates(
                        item_value,
                        item_definitions,
                        "#{path}[#{index}]",
                        context: context,
                    )
                end

                normalized_values
            end

            # Hashをキー候補構造として検査し、正規化する。
            def validate_hash_value(value, definition, path, context:)
                unless value.instance_of?(Hash)
                    raise DefinitionMismatch,
                        "#{path} は Hash で指定してください: #{value.inspect}"
                end

                validate_hash_item_count(value, definition, path)
                validate_must_not_keys(value, definition, path)
                validate_must_keys(value, definition, path)

                unless definition.key?(:items)
                    return deep_copy_value(value)
                end

                items = definition[:items]

                unless items.instance_of?(Array)
                    raise ArgumentError,
                        "#{path} の Hash用 :items は Array で指定してください"
                end

                validate_choice_hash_value(
                    value,
                    definition,
                    items,
                    path,
                    context: context,
                )
            end

            # item_count が指定されているHashの要素数を確認する。
            def validate_hash_item_count(value, definition, path)
                return unless definition.key?(:item_count)

                item_count = definition[:item_count]
                return if value.length == item_count

                raise DefinitionMismatch,
                    "#{path} は #{item_count} 件で指定してください: #{value.inspect}"
            end

            # items: Array のキー候補構造を検査し、正規化済みHashを返す。
            def validate_choice_hash_value(value, definition, item_definitions, path, context:)
                validate_hash_entry_definitions(
                    item_definitions,
                    path,
                )

                if value.empty?
                    raise DefinitionMismatch,
                        "#{path} は1件以上指定してください"
                end

                normalized_hash = {}

                value.each do |raw_key, raw_value|
                    normalized_entry = validate_hash_entry(
                        raw_key,
                        raw_value,
                        item_definitions,
                        path,
                        context: context,
                    )

                    normalized_key = normalized_entry[0]
                    normalized_value = normalized_entry[1]

                    if normalized_hash.key?(normalized_key)
                        raise DefinitionMismatch,
                            "#{path} に正規化後のキーが重複しています: #{normalized_key.inspect}"
                    end

                    normalized_hash[normalized_key] = normalized_value
                end

                normalized_hash
            end

            # Hash要素の候補定義に、キーを選択する条件が存在することを確認する。
            # 入力値との不一致ではなく定義自体の破綻なので、ArgumentErrorをそのまま返す。
            def validate_hash_entry_definitions(item_definitions, path)
                item_definitions.each_with_index do |item_definition, index|
                    unless item_definition.instance_of?(Hash)
                        raise ArgumentError,
                            "#{path} のHash要素定義[#{index}]は Hash で指定してください"
                    end

                    unless item_definition.key?(:item_type)
                        raise ArgumentError,
                            "#{path} のHash要素定義[#{index}]に :item_type がありません"
                    end

                    has_key_name = item_definition.key?(:key_name)
                    has_key_type = item_definition.key?(:key_type)

                    if has_key_name == false && has_key_type == false
                        raise ArgumentError,
                            "#{path} のHash要素定義[#{index}]に :key_name / :key_type がありません"
                    end

                    if has_key_name && has_key_type
                        raise ArgumentError,
                            "#{path} のHash要素定義[#{index}]に :key_name と :key_type は同時に指定できません"
                    end
                end
            end

            # must_keys に指定された固定キーがHash内に存在することを確認する。
            def validate_must_keys(value, definition, path)
                return unless definition.key?(:must_keys)

                normalized_keys = normalize_hash_keys(value, path)
                missing_keys = definition[:must_keys] - normalized_keys
                return if missing_keys.empty?

                raise DefinitionMismatch,
                    "#{path} に必要なキーがありません: #{missing_keys.inspect}"
            end

            # must_not_keys に指定された固定キーがHash内に存在しないことを確認する。
            def validate_must_not_keys(value, definition, path)
                return unless definition.key?(:must_not_keys)

                normalized_keys = normalize_hash_keys(value, path)
                prohibited_keys = definition[:must_not_keys] & normalized_keys
                return if prohibited_keys.empty?

                raise DefinitionMismatch,
                    "#{path} に指定できないキーがあります: #{prohibited_keys.inspect}"
            end

            # HashのString / Symbolキーを、固定キー制約の比較用にSymbolへ正規化する。
            def normalize_hash_keys(value, path)
                normalized_keys = []

                value.each_key do |raw_key|
                    begin
                        normalized_keys << normalize_symbol_key(
                            raw_key,
                            "#{path} のキー",
                        )
                    rescue DefinitionMismatch
                        next
                    end
                end

                normalized_keys
            end

            # Hashの1要素に一致するキー候補を選び、キーと値を正規化する。
            def validate_hash_entry(raw_key, raw_value, item_definitions, path, context:)
                specific_definitions = matching_key_name_definitions(
                    raw_key,
                    item_definitions,
                )

                candidate_definitions = specific_definitions
                if candidate_definitions.empty?
                    candidate_definitions = item_definitions.select do |definition|
                        definition.key?(:key_type)
                    end
                end

                mismatch_messages = []

                candidate_definitions.each_with_index do |definition, index|
                    begin
                        normalized_key = normalize_definition_key(
                            raw_key,
                            definition,
                            "#{path} のキー",
                            context: context,
                        )

                        normalized_value = validate_definition_node(
                            raw_value,
                            definition,
                            "#{path}[#{normalized_key.inspect}]",
                            context: context,
                        )

                        return [normalized_key, normalized_value]
                    rescue DefinitionMismatch => e
                        mismatch_messages << "候補#{index}: #{e.message}"
                    end
                end

                raise DefinitionMismatch,
                    "#{path} のキー #{raw_key.inspect} が定義に一致しません: " \
                    "#{mismatch_messages.join(' / ')}"
            end

            # 同名固定キー候補が存在する場合、汎用key_typeへ逃がさないため先に集める。
            def matching_key_name_definitions(raw_key, item_definitions)
                normalized_key = nil

                begin
                    normalized_key = normalize_symbol_key(
                        raw_key,
                        "Hash のキー",
                    )
                rescue DefinitionMismatch
                    return []
                end

                definitions = []

                item_definitions.each do |definition|
                    next unless definition.key?(:key_name)
                    next unless definition[:key_name] == normalized_key

                    definitions << definition
                end

                definitions
            end

            # key_nameまたはkey_typeに従ってHashキーを正規化する。
            def normalize_definition_key(raw_key, definition, path, context:)
                if definition.key?(:key_name)
                    normalized_key = normalize_symbol_key(raw_key, path)
                    expected_key = definition[:key_name]

                    unless normalized_key == expected_key
                        raise DefinitionMismatch,
                            "#{path} は #{expected_key.inspect} ではありません: #{raw_key.inspect}"
                    end

                    return expected_key
                end

                unless definition.key?(:key_type)
                    raise ArgumentError,
                        "#{path} のHash要素定義に :key_name / :key_type がありません"
                end

                normalize_key_type(
                    raw_key,
                    definition[:key_type],
                    path,
                    context: context,
                )
            end

            # 独自key_typeに従ってHashキーを検査し、正規化する。
            def normalize_key_type(raw_key, key_type, path, context:)
                case key_type
                when "symbol_key"
                    normalize_symbol_key(raw_key, path)
                when "field_name"
                    normalize_field_name(raw_key, path)
                when "sort_field"
                    normalize_sort_field(raw_key, context, path)
                when "any_valid_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :any_fields, path)
                when "all_valid_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :all_fields, path)
                when "any_valid_text_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :any_valid_text_fields, path)
                when "all_valid_text_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :all_valid_text_fields, path)
                when "any_valid_text_or_keyword_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :any_valid_text_or_keyword_fields, path)
                when "all_valid_text_or_keyword_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :all_valid_text_or_keyword_fields, path)
                when "any_valid_non_text_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :any_valid_non_text_fields, path)
                when "all_valid_non_text_field"
                    field_name = normalize_field_name(raw_key, path)
                    validate_context_field(field_name, context, :all_valid_non_text_fields, path)
                when "model_class"
                    normalize_model_class(raw_key, path)
                when "valid_model"
                    model = normalize_model_class(raw_key, path)
                    validate_context_model(model, context, path)
                else
                    raise ArgumentError,
                        "未知の key_type です: #{key_type.inspect}"
                end
            end

            # Classまたは独自item_typeに従って単一値を検査し、正規化する。
            def validate_scalar_value(value, item_type, path, context:)
                if item_type.instance_of?(Class)
                    unless value.instance_of?(item_type)
                        raise DefinitionMismatch,
                            "#{path} は #{item_type} で指定してください: #{value.inspect}"
                    end

                    return deep_copy_value(value)
                end

                unless item_type.instance_of?(String)
                    raise ArgumentError,
                        "#{path} の item_type は Class または String で指定してください"
                end

                validate_named_item_type(
                    value,
                    item_type,
                    path,
                    context: context,
                )
            end

            # 独自item_typeごとの値検査と正規化を行う。
            def validate_named_item_type(value, item_type, path, context:)
                case item_type
                when "any"
                    deep_copy_value(value)
                when "not_nil"
                    validate_not_nil_value(value, path)
                when "boolean"
                    validate_boolean_value(value, path)
                when "str_or_sym"
                    validate_str_or_sym_value(value, path)
                when "str_or_int"
                    validate_str_or_int_value(value, path)
                when "str_or_int_or_bool"
                    validate_str_or_int_or_bool_value(value, path)
                when "positive_number"
                    validate_positive_number(value, path)
                when "positive_integer"
                    validate_positive_integer(value, path)
                when "search_field"
                    normalize_search_field(value, path)
                when "sort_field"
                    normalize_sort_field(value, context, path)
                when "any_valid_search_field"
                    search_field = normalize_search_field(value, path)
                    validate_context_search_field(search_field, context, :any_fields, path)
                when "all_valid_search_field"
                    search_field = normalize_search_field(value, path)
                    validate_context_search_field(search_field, context, :all_fields, path)
                when "any_valid_text_search_field"
                    search_field = normalize_search_field(value, path)
                    validate_context_search_field(search_field, context, :any_valid_text_fields, path)
                when "all_valid_text_search_field"
                    search_field = normalize_search_field(value, path)
                    validate_context_search_field(search_field, context, :all_valid_text_fields, path)
                when "field_name"
                    normalize_field_name(value, path)
                when "any_valid_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :any_fields, path)
                when "all_valid_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :all_fields, path)
                when "any_valid_text_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :any_valid_text_fields, path)
                when "all_valid_text_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :all_valid_text_fields, path)
                when "any_valid_text_or_keyword_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :any_valid_text_or_keyword_fields, path)
                when "all_valid_text_or_keyword_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :all_valid_text_or_keyword_fields, path)
                when "any_valid_non_text_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :any_valid_non_text_fields, path)
                when "all_valid_non_text_field"
                    field_name = normalize_field_name(value, path)
                    validate_context_field(field_name, context, :all_valid_non_text_fields, path)
                when "model_class"
                    normalize_model_class(value, path)
                when "valid_model"
                    model = normalize_model_class(value, path)
                    validate_context_model(model, context, path)
                when "searchable_instance"
                    validate_searchable_instance(value, path)
                when "index_target"
                    validate_index_target(value, path)
                else
                    raise ArgumentError,
                        "未知の item_type です: #{item_type.inspect}"
                end
            end

            # 値の型は限定せず、nil だけを拒否して入力とは別の値を返す。
            def validate_not_nil_value(value, path)
                if value.nil?
                    raise DefinitionMismatch,
                        "#{path} に nil は指定できません"
                end

                deep_copy_value(value)
            end

            # boolean型としてtrueまたはfalseだけを許可する。
            def validate_boolean_value(value, path)
                return value if value == true
                return value if value == false

                raise DefinitionMismatch,
                    "#{path} は true または false で指定してください: #{value.inspect}"
            end

            # StringまたはSymbolの単一値だけを許可する。
            def validate_str_or_sym_value(value, path)
                if value.instance_of?(String)
                    return value
                end

                if value.instance_of?(Symbol)
                    return value
                end

                raise DefinitionMismatch,
                    "#{path} は String または Symbol で指定してください: #{value.inspect}"
            end

            # StringまたはIntegerの単一値だけを許可する。
            def validate_str_or_int_value(value, path)
                if value.instance_of?(String)
                    return value
                end

                if value.instance_of?(Integer)
                    return value
                end

                raise DefinitionMismatch,
                    "#{path} は String または Integer で指定してください: #{value.inspect}"
            end

            # String、Integer、true、falseの単一値だけを許可する。
            def validate_str_or_int_or_bool_value(value, path)
                if value.instance_of?(String)
                    return value
                end

                if value.instance_of?(Integer)
                    return value
                end

                if value == true
                    return value
                end

                if value == false
                    return value
                end

                raise DefinitionMismatch,
                    "#{path} は String、Integer、true、falseのいずれかで指定してください: #{value.inspect}"
            end

            # 正のIntegerまたはFloatだけを許可する。
            def validate_positive_number(value, path)
                numeric = value.instance_of?(Integer) || value.instance_of?(Float)

                if numeric && value > 0
                    return value
                end

                raise DefinitionMismatch,
                    "#{path} は正の数で指定してください: #{value.inspect}"
            end

            # 正のIntegerだけを許可する。
            def validate_positive_integer(value, path)
                if value.instance_of?(Integer) && value > 0
                    return value
                end

                raise DefinitionMismatch,
                    "#{path} は正の整数で指定してください: #{value.inspect}"
            end

            # sort対象をSymbol化する。
            # _score / _doc はElasticsearchの特別なsort値として許可する。
            # 通常フィールドは、全targetに存在する非textフィールドだけを許可する。
            def normalize_sort_field(value, context, path)
                field_name = normalize_field_name(value, path)

                return field_name if field_name == :_score
                return field_name if field_name == :_doc

                validate_context_field(
                    field_name,
                    context,
                    :all_valid_non_text_fields,
                    path,
                )
            end

            # 検索フィールド名をSymbol化し、^boost表記をfield/boostへ分割する。
            def normalize_search_field(value, path)
                unless value.instance_of?(String) || value.instance_of?(Symbol)
                    raise DefinitionMismatch,
                        "#{path} はフィールド名で指定してください: #{value.inspect}"
                end

                field_expression = value.to_s
                expression_parts = field_expression.split("^", -1)

                if expression_parts.length > 2
                    raise DefinitionMismatch,
                        "#{path} の ^ boost 表記が不正です: #{value.inspect}"
                end

                field_name = normalize_field_name(
                    expression_parts[0],
                    path,
                )

                boost = nil
                if expression_parts.length == 2
                    boost = parse_boost_value(
                        expression_parts[1],
                        path,
                    )
                end

                {
                    field: field_name,
                    boost: boost,
                }
            end

            # boost文字列を正のFloatへ変換する。
            def parse_boost_value(value, path)
                unless value.match?(/\A(?:\d+(?:\.\d+)?|\.\d+)\z/)
                    raise DefinitionMismatch,
                        "#{path} の boost は正の数で指定してください: #{value.inspect}"
                end

                boost = value.to_f
                return boost if boost > 0

                raise DefinitionMismatch,
                    "#{path} の boost は正の数で指定してください: #{value.inspect}"
            end

            # boostを持たないフィールド名をSymbolへ統一する。
            def normalize_field_name(value, path)
                unless value.instance_of?(String) || value.instance_of?(Symbol)
                    raise DefinitionMismatch,
                        "#{path} はフィールド名で指定してください: #{value.inspect}"
                end

                field_name = value.to_s

                if field_name.empty?
                    raise DefinitionMismatch,
                        "#{path} に空のフィールド名は指定できません"
                end

                if field_name.include?("^")
                    raise DefinitionMismatch,
                        "#{path} に ^ boost 表記は指定できません: #{value.inspect}"
                end

                field_name.to_sym
            end

            # Searchableをincludeしたインスタンスだけを許可する。
            def validate_searchable_instance(value, path)
                searchable = value.class.include?(AreSearch::Searchable)
                return value if searchable

                raise DefinitionMismatch,
                    "#{path} は AreSearch::Searchable のインスタンスで指定してください: #{value.inspect}"
            end

            # IndexTargetのインスタンスだけを許可する。
            def validate_index_target(value, path)
                if value.instance_of?(AreSearch::IndexTarget)
                    return value
                end

                raise DefinitionMismatch,
                    "#{path} は AreSearch::IndexTarget で指定してください: #{value.inspect}"
            end

            # モデル指定としてClassだけを許可する。
            def normalize_model_class(value, path)
                return value if value.instance_of?(Class)

                raise DefinitionMismatch,
                    "#{path} はモデルClassで指定してください: #{value.inspect}"
            end

            # StringまたはSymbolのHashキーをSymbolへ統一する。
            def normalize_symbol_key(value, path)
                if value.instance_of?(Symbol)
                    return value
                end

                if value.instance_of?(String) && value.empty? == false
                    return value.to_sym
                end

                raise DefinitionMismatch,
                    "#{path} は String または Symbol で指定してください: #{value.inspect}"
            end

            # オプション固有の入力形式を、後続処理が扱う単一形式へ揃える。
            def normalize_option_value(option_name, value, path)
                case option_name
                when :fields
                    normalize_fields_option(value, path)
                else
                    value
                end
            end

            # fieldsのArray/Hash両形式をfield/boost HashのArrayへ揃える。
            def normalize_fields_option(value, path)
                if value.instance_of?(Array)
                    return value
                end

                normalized_fields = []

                value.each do |field_name, boost|
                    normalized_fields << {
                        field: field_name,
                        boost: boost,
                    }
                end

                normalized_fields
            end

            # 入力を変更しないため、HashとArrayだけを再帰的に複製する。
            def deep_copy_value(value)
                if value.instance_of?(Hash)
                    copied_hash = {}

                    value.each do |key, child_value|
                        copied_hash[key] = deep_copy_value(child_value)
                    end

                    return copied_hash
                end

                if value.instance_of?(Array)
                    copied_array = []

                    value.each do |child_value|
                        copied_array << deep_copy_value(child_value)
                    end

                    return copied_array
                end

                value
            end
        end
    end
end
