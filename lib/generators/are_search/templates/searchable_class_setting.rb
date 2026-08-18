# frozen_string_literal: true

AreSearch.searchable_class_setting = {

    # SearchableモデルのIndexTarget・sync stage構成を定義する。
    # "Article" => {
    #     default: {
    #         index_target_name_alias: :alias_name,
    #         settings: {
    #             max_result_window: 2_000,
    #         },
    #         mappings: {
    #             _source: {
    #                 includes: [...],
    #             },
    #         },
    #         properties_method: :default_properties,
    #         indexable_method: :default_indexable?,
    #         stages: {
    #             "default" => {
    #                 data_method: :default_search_data,
    #                 enqueue: true,
    #                 after_commit: true,
    #             },
    #             "with_external_file" => {
    #                 data_method: :with_external_file_search_data,
    #                 enqueue: false,
    #                 after_commit: false,
    #             },
    #         },
    #     },
    #     _callbacks: {
    #         before_sync_check: :default_before_sync_check,
    #         after_sync_callback: :default_after_sync_callback,
    #     },
    # },
}
