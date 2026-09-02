# frozen_string_literal: true

module AreSearch
    class SearchParamLengthPolicy < SearchParamPolicy

        VALID_TEXT_PATTERN = /\A[\p{L}\p{M}\p{N}\p{P}\p{S}\p{Zs}]*\z/

        class << self

            # query_string系の検索パラメーターの値の検査
            def check_text(name, value)
                unless valid_value?(value)
                    return "#{name} は 不正な文字が含まれています。"
                end

                case name
                when 'query_string'
                    return "#{name} は 2048 文字以内で指定してください" if value.to_s.length > 2048
                when 'suggest.text'
                    return "#{name} は 128 文字以内で指定してください" if value.to_s.length > 128
                end

                nil
            end

            # where系の検索パラメーターの値の検査
            def check_field_value(field_name, name, value)
                unless valid_value?(value)
                    return "#{name} は 不正な文字が含まれています。"
                end

                case name
                when 'where.term'
                    return "#{name} は 128 文字以内で指定してください" if value.to_s.length > 128
                when 'where.terms'
                    return "#{name} は 1024 文字以内で指定してください" if value.to_s.length > 1024
                when 'where.range'
                    return "#{name} は 256 文字以内で指定してください" if value.to_s.length > 256
                end

                nil
            end

            def valid_value?(value)
                return true if value == nil

                if value.instance_of?(String)
                    return value.match?(VALID_TEXT_PATTERN)
                end

                if value.instance_of?(Integer) || value.instance_of?(Float) || value == true || value == false
                    return true
                end

                if value.instance_of?(Array)
                    value.each do |child_value|
                        return false if valid_value?(child_value) == false
                    end

                    return true
                end

                if value.instance_of?(Hash)
                    value.each do |child_key, child_value|
                        return false if valid_value?(child_key.to_s) == false
                        return false if valid_value?(child_value) == false
                    end

                    return true
                end

                false
            end
        end
    end
end
