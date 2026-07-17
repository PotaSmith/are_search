# frozen_string_literal: true

require "json"

module AreSearch
    # Elasticsearchへ送信するbodyとfield名からscript系キーを拒否する標準policy。
    class ScriptDenyEsSearchBodyPolicy < EsSearchBodyPolicy
        class << self
            # Elasticsearch serializerでJSON化した結果を走査する。
            def valid?(es_params)
                serialized_params = Elasticsearch::API.serializer.dump(es_params)
                normalized_params = JSON.parse(serialized_params)

                contains_script_key?(normalized_params) == false
            end

            # Elasticsearchのscript系キー名かを判定する。
            def invalid_key?(key_name)
                normalized_key_name = key_name.to_s

                return true if normalized_key_name == "script"
                return true if normalized_key_name.start_with?("script_")
                return true if normalized_key_name.end_with?("_script")

                false
            end

            private

            # JSON化後のHashとArrayを再帰的に走査する。
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

                false
            end
        end
    end
end
