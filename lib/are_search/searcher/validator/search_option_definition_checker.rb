# frozen_string_literal: true

module AreSearch
    class SearchOptionDefinitionChecker
        class << self

            # OPTION_DEFINITIONS 全体が検索オプション定義の記述形式に従っているか確認する。
            # 独自 item_type と key_type は SearchOptionValidator の対応一覧と照合する。
            def validate_option_definitions!(definitions = AreSearch::Searcher::OPTION_DEFINITIONS)
                unless definitions.instance_of?(Hash)
                    raise ArgumentError,
                        "OPTION_DEFINITIONS は Hash で指定してください: #{definitions.inspect}"
                end

                if definitions.empty?
                    raise ArgumentError,
                        "OPTION_DEFINITIONS には1件以上のオプション定義が必要です"
                end

                definitions.each do |option_name, option_definitions|
                    validate_option_name!(option_name)
                    validate_option_definition_list!(
                        option_name,
                        option_definitions,
                    )
                end

                true
            end

            private

            # OPTION_DEFINITIONS のトップレベルキーが Symbol であることを確認する。
            def validate_option_name!(option_name)
                return if option_name.instance_of?(Symbol)

                raise ArgumentError,
                    "OPTION_DEFINITIONS のオプション名は Symbol で指定してください: #{option_name.inspect}"
            end

            # 1つの検索オプションに、1件以上の候補定義があることを確認する。
            def validate_option_definition_list!(option_name, option_definitions)
                unless option_definitions.instance_of?(Array)
                    raise ArgumentError,
                        "OPTION_DEFINITIONS[:#{option_name}] は Array で指定してください: #{option_definitions.inspect}"
                end

                if option_definitions.empty?
                    raise ArgumentError,
                        "OPTION_DEFINITIONS[:#{option_name}] には1件以上の定義が必要です"
                end

                option_definitions.each_with_index do |definition, index|
                    validate_definition_node!(
                        definition,
                        "OPTION_DEFINITIONS[:#{option_name}][#{index}]",
                        position: :root,
                    )
                end
            end

            # 1件の定義ノードについて、許可キーと各値の形式を確認する。
            def validate_definition_node!(definition, path, position:)
                unless definition.instance_of?(Hash)
                    raise ArgumentError,
                        "#{path} は Hash で指定してください: #{definition.inspect}"
                end

                validate_definition_keys!(definition, path, position: position)

                unless definition.key?(:item_type)
                    raise ArgumentError,
                        "#{path} に :item_type がありません"
                end

                validate_item_type!(definition[:item_type], path)
                validate_key_selector!(definition, path, position: position)
                validate_item_count!(definition, path)
                validate_allow_empty!(definition, path)
                validate_must_keys!(definition, path)
                validate_must_not_keys!(definition, path)
                validate_hash_key_constraints!(definition, path)
                validate_items!(definition, path)
            end

            # 定義ノードに SearchOptionValidator が認識しないキーがないことを確認する。
            def validate_definition_keys!(definition, path, position:)
                valid_keys = AreSearch::SearchOptionValidator::ITEM_DEFINITION_KEYS

                unknown_keys = definition.keys - valid_keys
                if unknown_keys.any?
                    raise ArgumentError,
                        "#{path} に未知のキーがあります: #{unknown_keys.inspect}"
                end

                return if position == :hash_item

                invalid_keys = definition.keys & [:key_name, :key_type]
                return if invalid_keys.empty?

                raise ArgumentError,
                    "#{path} に #{invalid_keys.inspect} は指定できません"
            end

            # item_type が Class またはSearchOptionValidator対応済みの独自型名であることを確認する。
            def validate_item_type!(item_type, path)
                return if item_type.instance_of?(Class)

                unless item_type.instance_of?(String)
                    raise ArgumentError,
                        "#{path} の :item_type は Class または String で指定してください: #{item_type.inspect}"
                end

                return if AreSearch::SearchOptionValidator::NAMED_ITEM_TYPES.include?(item_type)

                raise ArgumentError,
                    "#{path} の :item_type は未知の独自型です: #{item_type.inspect}"
            end

            # Hash のキー候補では key_name または key_type の片方だけがあることを確認する。
            def validate_key_selector!(definition, path, position:)
                return if position != :hash_item

                key_name_exists = definition.key?(:key_name)
                key_type_exists = definition.key?(:key_type)

                if key_name_exists == key_type_exists
                    raise ArgumentError,
                        "#{path} は :key_name または :key_type のどちらか一方を指定してください"
                end

                if key_name_exists
                    validate_key_name!(definition[:key_name], path)
                    return
                end

                validate_key_type!(definition[:key_type], path)
            end

            # key_name が固定キー名を表す Symbol であることを確認する。
            def validate_key_name!(key_name, path)
                return if key_name.instance_of?(Symbol)

                raise ArgumentError,
                    "#{path} の :key_name は Symbol で指定してください: #{key_name.inspect}"
            end

            # key_type がSearchOptionValidator対応済みの独自キー判定名であることを確認する。
            def validate_key_type!(key_type, path)
                unless key_type.instance_of?(String)
                    raise ArgumentError,
                        "#{path} の :key_type は String で指定してください: #{key_type.inspect}"
                end

                return if AreSearch::SearchOptionValidator::NAMED_KEY_TYPES.include?(key_type)

                raise ArgumentError,
                    "#{path} の :key_type は未知の独自型です: #{key_type.inspect}"
            end

            # item_count が Hash の要素数を表す0以上の Integer であることを確認する。
            def validate_item_count!(definition, path)
                return unless definition.key?(:item_count)

                unless definition[:item_type] == Hash
                    raise ArgumentError,
                        "#{path} の :item_count は :item_type が Hash の場合だけ指定できます"
                end

                item_count = definition[:item_count]
                unless item_count.instance_of?(Integer) && item_count >= 0
                    raise ArgumentError,
                        "#{path} の :item_count は0以上の Integer で指定してください: #{item_count.inspect}"
                end

            end

            # allow_empty が Array の空要素許可を表す true であることを確認する。
            def validate_allow_empty!(definition, path)
                return unless definition.key?(:allow_empty)

                unless definition[:item_type] == Array
                    raise ArgumentError,
                        "#{path} の :allow_empty は :item_type が Array の場合だけ指定できます"
                end

                return if definition[:allow_empty] == true

                raise ArgumentError,
                    "#{path} の :allow_empty は true で指定してください: #{definition[:allow_empty].inspect}"
            end

            # must_keys が Hash に必要な固定キー名の配列として記述されているか確認する。
            def validate_must_keys!(definition, path)
                return unless definition.key?(:must_keys)

                validate_hash_key_list!(definition, :must_keys, path)
            end

            # must_not_keys が Hash に禁止する固定キー名の配列として記述されているか確認する。
            def validate_must_not_keys!(definition, path)
                return unless definition.key?(:must_not_keys)

                validate_hash_key_list!(definition, :must_not_keys, path)
            end

            # Hashの固定キー制約が、重複のないSymbol配列で記述されているか確認する。
            def validate_hash_key_list!(definition, definition_key, path)
                unless definition[:item_type] == Hash
                    raise ArgumentError,
                        "#{path} の :#{definition_key} は :item_type が Hash の場合だけ指定できます"
                end

                keys = definition[definition_key]
                unless keys.instance_of?(Array) && keys.empty? == false
                    raise ArgumentError,
                        "#{path} の :#{definition_key} は1件以上の Array で指定してください: #{keys.inspect}"
                end

                keys.each_with_index do |key, index|
                    unless key.instance_of?(Symbol)
                        raise ArgumentError,
                            "#{path}[:#{definition_key}][#{index}] は Symbol で指定してください: #{key.inspect}"
                    end
                end

                if keys.uniq.length != keys.length
                    raise ArgumentError,
                        "#{path} の :#{definition_key} に重複があります: #{keys.inspect}"
                end
            end

            # 必須キーと禁止キーに同じキーが指定された矛盾した定義を拒否する。
            def validate_hash_key_constraints!(definition, path)
                return unless definition.key?(:must_keys)
                return unless definition.key?(:must_not_keys)

                conflicting_keys = definition[:must_keys] & definition[:must_not_keys]
                return if conflicting_keys.empty?

                raise ArgumentError,
                    "#{path} の :must_keys と :must_not_keys に同じキーがあります: #{conflicting_keys.inspect}"
            end

            # items が候補一覧の Array として記述されているか確認する。
            def validate_items!(definition, path)
                return unless definition.key?(:items)

                items = definition[:items]
                item_type = definition[:item_type]

                unless item_type == Hash || item_type == Array
                    raise ArgumentError,
                        "#{path} の :items は :item_type が Hash または Array の場合だけ指定できます"
                end

                unless items.instance_of?(Array)
                    raise ArgumentError,
                        "#{path} の :items は Array で指定してください: #{items.inspect}"
                end

                validate_choice_items!(items, item_type, path)
            end

            # items: Array が Array要素またはHashキーの候補定義として記述されているか確認する。
            def validate_choice_items!(items, item_type, path)
                if items.empty?
                    raise ArgumentError,
                        "#{path} の Array形式の :items には1件以上の候補定義が必要です"
                end

                child_position = :array_item
                if item_type == Hash
                    child_position = :hash_item
                end

                items.each_with_index do |child_definition, index|
                    validate_definition_node!(
                        child_definition,
                        "#{path}[:items][#{index}]",
                        position: child_position,
                    )
                end
            end
        end
    end
end
