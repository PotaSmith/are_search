# frozen_string_literal: true

module AreSearch
    class BodyBuilderBase
        class << self

            def must_params
                [].freeze
            end

            def must_not_params
                [].freeze
            end

            # SearchOptionValidatorでSymbol化済みのオプションから、
            # 必須・禁止オプションの組み合わせが一致するか確認する。
            def match?(valid_options)
                return false if must_params.nil? || must_not_params.nil?
                return false if must_params.empty? && must_not_params.empty?

                must_valid = must_params.all? do |name|
                    valid_options[name].nil? == false
                end

                must_not_valid = must_not_params.all? do |name|
                    valid_options[name].nil?
                end

                must_valid && must_not_valid
            end

            private

            # page / per_page から算出した from / size を max_result_window 内へ収める
            def resolve_paging_params(index_targets, from, size)
                max_result_window = resolve_max_result_window(index_targets)

                if from >= max_result_window
                    return [max_result_window, 0]
                end

                if from + size > max_result_window
                    size = max_result_window - from
                end

                size = 0 if size < 0

                [from, size]
            end

            # 最小の max_result_window を計算
            def resolve_max_result_window(index_targets)
                values = index_targets.map { |index_target| resolve_model_max_result_window(index_target) }

                values.min
            end

            # モデルごとの最小の max_result_window を計算
            def resolve_model_max_result_window(index_target)
                model_index_settings = index_target.are_search_es_index_settings

                model_index_settings[:max_result_window]
            end
        end
    end
end
