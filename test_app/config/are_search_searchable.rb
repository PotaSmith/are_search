# frozen_string_literal: true

AreSearch.searchable_class_setting = {
    "DocumentFirst" => {
        default: {
            settings: {
                max_result_window: 2_000,
            },
            mappings: {
                _source: {
                    includes: [
                        :multi_response_both,
                        :multi_response_first_only,
                    ],
                },
            },
            properties_method: :default_properties,
            indexable_method: :default_indexable?,
            stages: {
                "default" => {
                    data_method: :default_search_data,
                    enqueue: true,
                    after_commit: true,
                },
            },
        },
    },
    "DocumentSecond" => {
        default: {
            settings: {
                max_result_window: 2_000,
            },
            mappings: {
                _source: {
                    includes: [
                        :title,
                        :status,
                        :multi_response_both,
                        :multi_response_second_only,
                    ],
                },
            },
            properties_method: :default_properties,
            indexable_method: :default_indexable?,
            stages: {
                "default" => {
                    data_method: :default_search_data,
                    enqueue: true,
                    after_commit: true,
                },
            },
        },
    },
}
