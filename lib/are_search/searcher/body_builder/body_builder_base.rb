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

            # 検証済み page / per_page から Elasticsearch へ渡す from / size を算出する。
            def resolve_paging_params(max_result_window, page, per_page)
                from = (page - 1) * per_page
                size = per_page

                if from + size > max_result_window
                    size = max_result_window - from
                end

                [from, size]
            end

        end
    end
end
