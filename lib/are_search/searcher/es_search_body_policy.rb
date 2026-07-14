# frozen_string_literal: true

module AreSearch
    class EsSearchBodyPolicy
        class << self
            # Elasticsearchへ送信するパラメーターにscript系のキーが含まれていないか確認する
            def valid?(es_params)
                contains_script_key?(es_params) == false
            end

            # Elasticsearch の script 系キー名かを判定する。
            def invalid_key?(key_name)
                normalized_key_name = key_name.to_s

                return true if normalized_key_name == "script"
                return true if normalized_key_name.start_with?("script_")
                return true if normalized_key_name.end_with?("_script")

                false
            end

            private

            # HashとArrayを再帰的に走査し、script 系キーがあるか確認する。
            def contains_script_key?(value)
                if value.instance_of?(Hash)
                    value.each do |key, child_value|
                        return true if invalid_key?(key)
                        return true if contains_script_key?(child_value)
                    end

                    return false
                end

                if value.instance_of?(Array)
                    value.each do |child_value|
                        return true if contains_script_key?(child_value)
                    end

                    return false
                end

                return true if value.is_a?(Enumerable)

                false
            end
        end
    end
end
