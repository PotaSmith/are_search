# frozen_string_literal: true

module AreSearch
    module EsDataValidator
        extend self

        # Hash の key に AreSearch 予約フィールドが含まれていないか確認し、
        # 含まれている予約フィールド名を Symbol の配列で返す。
        # 利用側 key は Symbol / String のどちらもあり得るため両方を見る。
        def reserved_data_field_names(hash)
            reserved_names = []
            return reserved_names unless hash.instance_of?(Hash)

            AreSearch::RESERVED_ES_FIELD_NAMES.each do |reserved_name|
                if hash.key?(reserved_name)
                    reserved_names << reserved_name
                    next
                end

                if hash.key?(reserved_name.to_s)
                    reserved_names << reserved_name
                end
            end

            reserved_names
        end

        # mappings（型定義）と data（実データ）の整合性をチェックし、
        # 違反内容の文字列の配列を返す純粋メソッド。
        # 違反が無ければ空配列を返す。errors.add への変換は呼び出し側の責務。
        #
        # @param mappings [Hash] are_search_es_mappings の戻り値
        # @param data     [Hash] are_search_es_data の戻り値
        # @return [Array<String>]
        def validate(mappings, data)
            violations = []

            unless mappings.instance_of?(Hash)
                violations << "mappings が hash ではありません: #{mappings.inspect}"
            end
            unless data.instance_of?(Hash)
                violations << "data が hash ではありません: #{data.inspect}"
            end
            return violations if violations.any?

            validate_symbol_keys(violations, mappings, "mappings", 3)
            validate_symbol_keys(violations, data, "data", 1)
            return violations if violations.any?

            properties = mappings[:properties] || {}
            mapping_keys = properties.keys
            data_keys    = data.keys

            # --- キー集合の完全一致チェック ---
            # data 側にあって mappings 側に無いキー（余剰）
            extra_keys = data_keys - mapping_keys
            extra_keys.each do |key|
                violations << "mappings に定義の無いキーが data に含まれています: #{key}"
            end

            # mappings 側にあって data 側に無いキー（欠損）
            missing_keys = mapping_keys - data_keys
            missing_keys.each do |key|
                violations << "mappings に定義されているキーが data にありません: #{key}"
            end

            # --- 各フィールドの型チェック（両方に存在するキーのみ） ---
            common_keys = mapping_keys & data_keys
            common_keys.each do |key|
                es_type = properties[key][:type]
                value   = data[key]

                are_search_es_validate_value(violations, key, es_type, value)
            end

            violations
        end

        def validate_mapping_symbol_keys(mappings)
            violations = []

            validate_symbol_keys(violations, mappings, "mappings", 3)

            violations
        end

        private

        def validate_symbol_keys(violations, hash, path, remaining_depth)
            return unless hash.instance_of?(Hash)
            return if remaining_depth <= 0

            hash.each do |key, value|
                unless key.instance_of?(Symbol)
                    violations << "#{path} の key は Symbol で指定してください: #{key.inspect}"
                end

                child_path = "#{path}.#{key}"
                validate_symbol_keys(violations, value, child_path, remaining_depth - 1)
            end
        end

        # 単一値または配列の値を型チェックし、違反があれば violations に積む。
        # nil は対象外（ES が null を許容するため）。
        # 配列は各要素に対して単一値チェックを適用する（配列そのものは許容）。
        def are_search_es_validate_value(violations, key, es_type, value)
            return if value.nil?

            if value.is_a?(Array)
                value.each do |element|
                    are_search_es_validate_scalar(violations, key, es_type, element)
                end
                return
            end

            are_search_es_validate_scalar(violations, key, es_type, value)
        end

        # 単一値が es_type に厳密適合しているかチェックし、違反なら violations に積む。
        # 対応表に無い型は通す（ES に委ねる）。
        def are_search_es_validate_scalar(violations, key, es_type, value)
            case es_type.to_s
            when "text", "keyword"
                unless value.is_a?(String)
                    violations << "#{key} は #{es_type} 型ですが String ではありません: #{value.class}"
                end
            when "long", "integer", "short", "byte", "unsigned_long"
                unless value.is_a?(Integer)
                    violations << "#{key} は #{es_type} 型ですが Integer ではありません: #{value.class}"
                end
            when "double", "float", "half_float", "scaled_float"
                unless value.is_a?(Integer) || value.is_a?(Float)
                    violations << "#{key} は #{es_type} 型ですが Integer/Float ではありません: #{value.class}"
                end
            when "boolean"
                unless value == true || value == false
                    violations << "#{key} は #{es_type} 型ですが true/false ではありません: #{value.class}"
                end
            when "date"
                unless value.is_a?(Date) || value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(String) || value.is_a?(Integer)
                    violations << "#{key} は #{es_type} 型ですが Date/Time/DateTime/String/Integer ではありません: #{value.class}"
                end
            end
        end
    end
end
