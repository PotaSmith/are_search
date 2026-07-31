# frozen_string_literal: true

module AreSearch
    module QueryBuilderSelector
        extend self

        # 検索オプションの組み合わせに対応するQueryBuilderを返す
        def select(valid_options)
            if AreSearch::StandardQueryBuilder.match?(valid_options)
                return AreSearch::StandardQueryBuilder
            end

            if AreSearch::MoreLikeThisQueryBuilder.match?(valid_options)
                return AreSearch::MoreLikeThisQueryBuilder
            end

            if AreSearch::RawQueryBuilder.match?(valid_options)
                return AreSearch::RawQueryBuilder
            end

            raise ArgumentError, "検索パラメータが不正な組み合わせです。"
        end
    end
end
