# frozen_string_literal: true

module AreSearch
    class Error < StandardError; end

    # 外部入力として許可した検索値が定義に適合しないことを表す。
    class InvalidSearchOption < Error; end

    # 検索bodyが設定中のsearch body policyに拒否されたことを表す。
    class InvalidSearchBody < Error; end

    # 検索に必要なElasticsearch aliasが存在しないことを表す。
    class SearchIndexNotFound < Error; end

    class NotConfiguredError < Error; end
    class IndexOperationViolation < Error; end
    class RakeOperationViolation < Error; end
    class IndexLockUnavailable < Error; end
    class IndexMarkerUnavailable < Error; end
end
