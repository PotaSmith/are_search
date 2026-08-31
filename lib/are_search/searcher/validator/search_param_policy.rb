# frozen_string_literal: true

module AreSearch
    class SearchParamPolicy
        class << self

            # 継承先で1件の検索値を検査し、問題があればエラーメッセージを返す。
            def check_text(name, value)
                raise NotImplementedError, "#{self.name}.check_text を実装してください"
            end
            def check_field_value(field_name, name, value)
                raise NotImplementedError, "#{self.name}.check_field_value を実装してください"
            end

            # 検証済み検索オプションから外部入力値を取り出し、policyで検査する。
            def validate!(valid_options)
                valid_options.each do |key, value|
                    if key == :queries
                        next if value.nil?
                        value.each do |value_child|
                            message = check_text('query_string', value_child[:query_string])
                            if message != nil
                                raise AreSearch::InvalidSearchOption, message
                            end
                        end
                    end

                    if key == :suggest
                        next if value.nil?

                        value.each do |suggest_name, suggest_value|
                            if suggest_value.key?(:text)
                                message = check_text('suggest.text', suggest_value[:text])
                                if message != nil
                                    raise AreSearch::InvalidSearchOption, message
                                end
                            end
                        end
                    end

                    if key == :where
                        next if value.nil?

                        validate_where_values(value)
                    end
                end
            end

            # where以下のbool条件を再帰的に辿り、field条件の値をpolicyで検査する。
            def validate_where_values(bool_value)
                [:must, :filter, :should, :must_not].each do |clause_type|
                    condition_values = bool_value[clause_type]
                    next if condition_values.nil?

                    condition_values.each do |condition_value|
                        validate_where_condition(condition_value)
                    end
                end
            end

            # condition内のfield条件を検査し、bool条件なら再帰する。
            def validate_where_condition(condition_value)
                condition_value.each do |field_name, field_param|
                    if field_name == :bool
                        validate_where_values(field_param)
                        next
                    end

                    validate_where_field_value(field_name, field_param)
                end
            end

            # fieldのterm / terms / range値をpolicyへ渡す。
            def validate_where_field_value(field_name, field_param)
                return if field_param.nil?

                field_param.each do |param_type, param_value|
                    message = check_field_value(field_name, "where.#{param_type}", param_value)
                    if message != nil
                        raise AreSearch::InvalidSearchOption, message
                    end
                end
            end
        end
    end
end
