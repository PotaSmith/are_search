class DocumentFirst < ApplicationRecord
    include AreSearch::Searchable

    def self.default_properties
        {
            title:                     { type: "text" },
            body:                      { type: "text" },
            status:                    { type: "keyword" },
            user_id:                   { type: "long" },
            multi_response_both:       { type: "keyword", store: true, doc_values: true },
            multi_response_first_only: { type: "keyword", store: true, doc_values: true },
        }
    end

    def default_indexable?
        true
    end

    def default_search_data
        {
            title:                     title,
            body:                      body,
            status:                    status,
            user_id:                   user_id,
            multi_response_both:       "first both",
            multi_response_first_only: "first only",
        }
    end
end
