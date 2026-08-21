# frozen_string_literal: true

module AreSearch
    class SearchParamPolicy
        class << self

            # 継承先で1件の検索値を検査し、問題があればエラーメッセージを返す。
            def check_value(name, value)
                raise NotImplementedError, "#{self.name}.check_value を実装してください"
            end

            # 検証済み検索オプションから外部入力値を取り出し、policyで検査する。
            def validate!(valid_options)
                valid_options.each do |key, value|
                    if key == :queries
                        next if value.nil?
                        value.each do |value_child|
                            message = check_value('query_string', value_child[:query_string])
                            if message != nil
                                raise AreSearch::InvalidSearchOption, message
                            end
                        end
                    end

                    if [:where, :where_not, :where_or].include?(key)
                        next if value.nil?

                        condition_values = value.instance_of?(Array) ? value : [value]

                        condition_values.each do |condition_value|
                            condition_value.each do |field_name, field_param|
                                next if field_param.nil?
                                field_param.each do |param_type, param_value|
                                    message = check_value("#{key}.#{param_type}", param_value)
                                    if message != nil
                                        raise AreSearch::InvalidSearchOption, message
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
