# frozen_string_literal: true

module AreSearch
    class SearchParamLengthPolicy < SearchParamPolicy
        class << self

            # query_string系の検索パラメーターの値の検査
            def check_text(name, value)
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
        end
    end
end
