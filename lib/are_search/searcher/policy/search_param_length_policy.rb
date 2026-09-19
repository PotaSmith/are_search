# frozen_string_literal: true

module AreSearch
    class SearchParamLengthPolicy < SearchParamPolicy

        VALID_TEXT_PATTERN = /\A[\p{L}\p{M}\p{N}\p{P}\p{S}\p{Zs}]*\z/

        def initialize(
            query_string_max_length: 2048,
            suggest_text_max_length: 128,
            where_term_max_length: 128,
            where_terms_max_length: 1024,
            where_range_max_length: 256
        )
            @query_string_max_length = query_string_max_length
            @suggest_text_max_length = suggest_text_max_length
            @where_term_max_length = where_term_max_length
            @where_terms_max_length = where_terms_max_length
            @where_range_max_length = where_range_max_length
        end

        # query_string系の検索パラメーターの値の検査
        def check_text(name, value)
            if self.class.valid_value?(value) == false
                return "#{name} は 不正な文字が含まれています。"
            end

            case name
            when 'query_string'
                if value.to_s.length > @query_string_max_length
                    return "#{name} は #{@query_string_max_length} 文字以内で指定してください"
                end
            when 'suggest.text'
                if value.to_s.length > @suggest_text_max_length
                    return "#{name} は #{@suggest_text_max_length} 文字以内で指定してください"
                end
            end

            nil
        end

        # where系の検索パラメーターの値の検査
        def check_field_value(name, field_name, value)
            if self.class.valid_value?(value) == false
                return "#{name} は 不正な文字が含まれています。"
            end

            case name
            when 'where.term'
                if value.to_s.length > @where_term_max_length
                    return "#{name} は #{@where_term_max_length} 文字以内で指定してください"
                end
            when 'where.terms'
                if value.to_s.length > @where_terms_max_length
                    return "#{name} は #{@where_terms_max_length} 文字以内で指定してください"
                end
            when 'where.range'
                if value.to_s.length > @where_range_max_length
                    return "#{name} は #{@where_range_max_length} 文字以内で指定してください"
                end
            end

            nil
        end

        def self.valid_value?(value)
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
