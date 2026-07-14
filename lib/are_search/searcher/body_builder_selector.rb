# frozen_string_literal: true

module AreSearch
    module BodyBuilderSelector
        extend self

        def select(valid_options)
            if AreSearch::StandardBodyBuilder.match?(valid_options)
                return AreSearch::StandardBodyBuilder

            elsif AreSearch::RawBodyBuilder.match?(valid_options)
                return AreSearch::RawBodyBuilder

            else
                raise ArgumentError, "検索パラメータが不正な組み合わせです。"
            end
        end
    end
end
