# frozen_string_literal: true

module AreSearch
    module IndexDataValidator
        extend self

        # Hash の key に AreSearch 予約フィールドが含まれていないか確認し、
        # 含まれている予約フィールド名を Symbol の配列で返す。
        # 利用側 data の key は Symbol / String のどちらもあり得るため両方を見る。
        def find_reserved_index_field_names(hash)
            reserved_names = []
            return reserved_names unless hash.instance_of?(Hash)

            AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAMES.each do |reserved_name|
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

        # 検査済み mappings と are_search_index_data の整合性を確認する。
        # このクラスは実データだけを担当し、mappings 定義自体の検査は行わない。
        # 違反内容の文字列配列を返し、違反が無ければ空配列を返す。
        #
        # @param mappings [Hash] 検査済みの target mappings
        # @param data     [Hash] are_search_index_data の戻り値
        # @return [Array<String>]
        def validate(mappings, data)
            violations = []

            unless data.instance_of?(Hash)
                violations << "data が hash ではありません: #{data.inspect}"
                return violations
            end

            validate_data_symbol_keys(violations, data)
            return violations if violations.any?

            properties = mappings[:properties]
            mapping_keys = properties.keys
            data_keys = data.keys

            extra_keys = data_keys - mapping_keys
            extra_keys.each do |key|
                violations << "mappings に定義の無いキーが data に含まれています: #{key}"
            end

            missing_keys = mapping_keys - data_keys
            missing_keys.each do |key|
                violations << "mappings に定義されているキーが data にありません: #{key}"
            end

            common_keys = mapping_keys & data_keys
            common_keys.each do |key|
                es_type = properties[key][:type]
                value = data[key]

                validate_value(violations, key, es_type, value)
            end

            violations
        end

        private

        # are_search_index_data のトップレベル key が Symbol か確認する。
        def validate_data_symbol_keys(violations, data)
            data.each_key do |key|
                unless key.instance_of?(Symbol)
                    violations << "data の key は Symbol で指定してください: #{key.inspect}"
                end
            end
        end

        # 単一値または配列の値を型チェックし、違反があれば violations に積む。
        # nil は対象外とし、配列は各要素へ単一値チェックを適用する。
        def validate_value(violations, key, es_type, value)
            return if value.nil?

            if value.is_a?(Array)
                value.each do |element|
                    validate_scalar(violations, key, es_type, element)
                end
                return
            end

            validate_scalar(violations, key, es_type, value)
        end

        # 単一値が mapping type に適合するか確認する。
        # 対応表に無い型は Elasticsearch に委ねる。
        def validate_scalar(violations, key, es_type, value)
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
