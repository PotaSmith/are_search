class DocumentFirst < ApplicationRecord
    include AreSearch::Searchable

    def self.are_search_index_mappings
        {
            default: {
                index_settings: {
                    max_result_window: 2_000,
                },
                _source: {
                    includes: [
                        :multi_response_both,
                        :multi_response_first_only,
                    ],
                },
                properties: {
                    title:                     { type: "text" },
                    body:                      { type: "text" },
                    status:                    { type: "keyword" },
                    user_id:                   { type: "long" },
                    multi_response_both:       { type: "keyword", store: true, doc_values: true },
                    multi_response_first_only: { type: "keyword", store: true, doc_values: true },
                },
            },
        }
    end

    def self.are_search_all_sync_stage_names
        {
            default: ["default"],
        }
    end

    def are_search_index_data(index_target_name, sync_stage_name)
        case [index_target_name, sync_stage_name]
        when [:default, "default"]
            {
                title:                     title,
                body:                      body,
                status:                    status,
                user_id:                   user_id,
                multi_response_both:       "first both",
                multi_response_first_only: "first only",
            }
        else
            {}
        end
    end
end
