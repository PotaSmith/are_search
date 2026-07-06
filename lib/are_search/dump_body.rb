# frozen_string_literal: true

module AreSearch
    # 検索を実行せず、組み立てられた検索 body（Hash）だけを返させるための
    # デバッグ用センチネル。
    #
    # are_search_es_search / MultiSearch / MoreLikeThis の検索語（MoreLikeThis では
    # instance 引数）の位置に AreSearch::DumpBody を渡すと、各検索メソッドは
    # ES へのリクエストを行わず、組み立てた body を返す。
    #
    # 使い方:
    #
    #   Article.are_search_es_search(AreSearch::DumpBody, fields: [:title])
    #   AreSearch::MultiSearch.search([Article], AreSearch::DumpBody, fields: [:title])
    #   AreSearch::MoreLikeThis.search([Article], AreSearch::DumpBody, fields: [:title])
    #
    # MoreLikeThis では like 句に index_target.are_search_es_index_name と
    # instance.id が使われるため、DumpBody がそれらに応答できるよう
    # クラスメソッド are_search_es_index_name とインスタンスメソッド id を持つ。
    #
    # body を puts / p / inspect した際に検索語の箇所が分かりやすく表示されるよう、
    # to_s / inspect も "<DUMP_BODY>" を返す。
    class DumpBodyClass
        PLACEHOLDER = "<DUMP_BODY>"

        def self.are_search_es_index_name
            PLACEHOLDER
        end

        def id
            PLACEHOLDER
        end

        def to_s
            PLACEHOLDER
        end

        def inspect
            PLACEHOLDER
        end
    end

    DumpBody = DumpBodyClass.new
end
