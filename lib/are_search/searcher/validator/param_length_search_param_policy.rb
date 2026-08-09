# frozen_string_literal: true

module AreSearch
    class ParamLengthSearchParamPolicy < SearchParamPolicy
        class << self

            # 検索パラメーターの値の検査
            def valid?(name, value)
                case name
                when 'query_string'
                    value.to_s.length <= 2048

                when 'where.term'
                    value.to_s.length <= 256
                when 'where.terms'
                    value.to_s.length <= 256
                when 'where.range'
                    value.to_s.length <= 256

                when 'where_not.term'
                    value.to_s.length <= 256
                when 'where_not.terms'
                    value.to_s.length <= 256
                when 'where_not.range'
                    value.to_s.length <= 256

                when 'where_or.term'
                    value.to_s.length <= 256
                when 'where_or.terms'
                    value.to_s.length <= 256
                when 'where_or.range'
                    value.to_s.length <= 256

                else
                    true
                end
            end
        end
    end
end
