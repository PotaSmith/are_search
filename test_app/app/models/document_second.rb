class DocumentSecond < ApplicationRecord
    include AreSearch::Searchable

    def self.default_properties
        {
            title:                      { type: "text" },
            body:                       { type: "text", store: true },
            status:                     { type: "keyword" },
            user_id:                    { type: "long" },
            multi_response_both:        { type: "keyword", store: true, doc_values: true },
            multi_response_second_only: { type: "keyword", store: true, doc_values: true },
        }
    end

    def default_indexable?
        true
    end

    # 標準IndexTargetへ保存する完成ドキュメントを返す。
    def default_search_data
        {
            title:                      title,
            body:                       body,
            status:                     status,
            user_id:                    user_id,
            multi_response_both:        "second both",
            multi_response_second_only: "second only",
        }
    end
end
