class DocumentSecond < ApplicationRecord
    include AreSearch::Searchable

    def self.are_search_index_mappings
        {
            default: {
                index_settings: {
                    max_result_window: 2_000,
                },
                _source: {
                    includes: [
                        :title,
                        :status,
                        :multi_response_both,
                        :multi_response_second_only,
                    ],
                },
                properties: {
                    title:                      { type: "text" },
                    body:                       { type: "text", store: true },
                    status:                     { type: "keyword" },
                    user_id:                    { type: "long" },
                    multi_response_both:        { type: "keyword", store: true, doc_values: true },
                    multi_response_second_only: { type: "keyword", store: true, doc_values: true },
                },
            },
        }
    end

    def self.are_search_all_sync_stage_names
        {
            default: ["default"],
        }
    end

    # 標準IndexTargetへ保存する完成ドキュメントを返す。
    def are_search_index_data(index_target_name, sync_stage_name)
        case [index_target_name, sync_stage_name]
        when [:default, "default"]
            {
                title:                      title,
                body:                       body,
                status:                     status,
                user_id:                    user_id,
                multi_response_both:        "second both",
                multi_response_second_only: "second only",
            }
        else
            {}
        end
    end
end
