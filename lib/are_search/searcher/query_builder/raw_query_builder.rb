# frozen_string_literal: true

module AreSearch
    class RawQueryBuilder < QueryBuilderBase
        class << self

            # Raw検索の選択に必要なオプションを返す
            def must_params
                [
                    :raw_body,
                ].freeze
            end

            # Raw検索と同時に指定できないオプションを返す
            def must_not_params
                [
                    :runtime_mappings,
                    :mlt,
                    :queries,
                    :where,
                    :where_not,
                    :where_or,
                    :aggs,
                    :sort,
                    :highlight,
                    :response,
                ].freeze
            end

            # Raw検索では query を組み立てず、body構築を RawBodyBuilder に委ねる
            def build(_index_targets, _valid_options)
                nil
            end
        end
    end
end
