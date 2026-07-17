# frozen_string_literal: true

# 検索オプション定義。
#
# 値が置かれる位置には、許可するnode_typeごとの定義を置く。
# node_typeの候補は :scalar / :hash / :array を最大1件ずつ指定する。
#
#     {
#         scalar: {
#             type: "string",
#         },
#         hash: {
#             key_values: [],
#         },
#         array: {
#             children: {},
#         },
#     }
#
# scalar nodeとHash keyは、どちらも単一値として共通の:typeで型を定義する。
# Hash keyの完全一致による選択だけは:key_nameで定義する。
#
# Hashだけは、各key_valueについてkeyによる定義選択を先に行う。
# 選択されたkey_value定義の:valueを、valueのnode_typeと組み合わせて再帰検査する。
#
#     {
#         hash: {
#             must_keys: [:fields],
#             must_not_keys: [:like],
#             item_count: 1,
#             key_values: [
#                 {
#                     key: {
#                         key_name: :fields,
#                     },
#                     value: {
#                         array: {
#                             children: {
#                                 scalar: {
#                                     type: "string",
#                                 },
#                             },
#                         },
#                     },
#                 },
#             ],
#         },
#     }
#
# Arrayはkey_value定義を持たない。
# 各要素をnodeとして、共通の:childrenと組み合わせて再帰検査する。
#
# Hashは:key_values、Arrayは:childrenを必ず持つ。
# 任意の内容を許可する場合も、任意node用の子定義を明示する。

module AreSearch
    module Searcher
        extend self

        # 検索オプション定義の:typeに指定できる名前付き型。
        OPTION_DEFINITION_TYPES = [
            "any",
            "string",
            "not_nil",
            "boolean",
            "str_or_sym",
            "str_or_int",
            "str_or_int_or_bool",
            "positive_number",
            "positive_integer",
            "symbol_key",
            "sort_field",
            "any_valid_field",
            "all_valid_field",
            "any_text_without_non_text_field",
            "all_valid_text_field",
            "any_text_or_keyword_without_other_type_field",
            "all_valid_text_or_keyword_field",
            "any_non_text_without_text_field",
            "all_valid_non_text_field",
            "model_class",
            "valid_model",
            "searchable_instance",
            "index_target",
        ].freeze

        # where系オプションの1フィールド分を検査するHash key_value定義。
        CONDITION_FIELD_KEY_VALUES = [
            {
                key: {
                    type: "any_non_text_without_text_field",
                },
                value: {
                    hash: {
                        item_count: 1,
                        key_values: [
                            {
                                key: {
                                    key_name: :term,
                                },
                                value: {
                                    scalar: {
                                        type: "str_or_int_or_bool",
                                    },
                                },
                            },
                            {
                                key: {
                                    key_name: :terms,
                                },
                                value: {
                                    array: {
                                        allow_empty: true,
                                        children: {
                                            scalar: {
                                                type: "str_or_int_or_bool",
                                            },
                                        },
                                    },
                                },
                            },
                            {
                                key: {
                                    key_name: :range,
                                },
                                value: {
                                    hash: {
                                        key_values: [
                                            {
                                                key: {
                                                    type: "symbol_key",
                                                },
                                                value: {
                                                    scalar: {
                                                        type: "str_or_int_or_bool",
                                                    },
                                                },
                                            },
                                        ],
                                    },
                                },
                            },
                        ],
                    },
                },
            },
        ].freeze

        # where系オプションのHash形式とArray形式を表すnode定義。
        CONDITION_DEFINITIONS = {
            hash: {
                key_values: CONDITION_FIELD_KEY_VALUES,
            },
            array: {
                children: {
                    hash: {
                        key_values: CONDITION_FIELD_KEY_VALUES,
                    },
                },
            },
        }.freeze

        # fieldsのArray形式とboost付きHash形式を表すnode定義。
        FIELDS_DEFINITIONS = {
            array: {
                children: {
                    scalar: {
                        type: "any_text_without_non_text_field",
                    },
                },
            },
            hash: {
                key_values: [
                    {
                        key: {
                            type: "any_text_without_non_text_field",
                        },
                        value: {
                            scalar: {
                                type: "positive_number",
                            },
                        },
                    },
                ],
            },
        }.freeze

        OPTION_DEFINITIONS = {
            # raw_body: {
            #     query: {
            #         match_all: {},
            #     },
            # }
            raw_body: {
                hash: {
                    allow_empty: true,
                    key_values: [
                        {
                            key: {
                                type: "any",
                            },
                            value: {
                                type: "any",
                            },
                        },
                    ],
                },
            },

            # build_model_bool: true
            build_model_bool: {
                scalar: {
                    type: "boolean",
                },
            },

            # query_string: "Rails"
            query_string: {
                scalar: {
                    type: "string",
                },
            },

            # fields: [:title, :body]
            #
            # fields: {
            #     title: 2.0,
            #     body:  1.0,
            # }
            fields: FIELDS_DEFINITIONS,

            # queries: [
            #     {
            #         query_string: "Rails",
            #         fields: [:title, :body],
            #     },
            #     {
            #         query_string: "Ruby",
            #         fields: {
            #             title: 2.0,
            #             body:  1.0,
            #         },
            #     },
            # ]
            queries: {
                array: {
                    children: {
                        hash: {
                            must_keys: [
                                :query_string,
                                :fields,
                            ],
                            key_values: [
                                {
                                    key: {
                                        key_name: :query_string,
                                    },
                                    value: {
                                        scalar: {
                                            type: "string",
                                        },
                                    },
                                },
                                {
                                    key: {
                                        key_name: :fields,
                                    },
                                    value: FIELDS_DEFINITIONS,
                                },
                            ],
                        },
                    },
                },
            },

            # mlt_instance: article
            mlt_instance: {
                scalar: {
                    type: "searchable_instance",
                },
            },

            # mlt_index_target: Article.are_search_index_target(:default)
            mlt_index_target: {
                scalar: {
                    type: "index_target",
                },
            },

            # mlt_params: {
            #     fields: [:title, :body],
            #     min_term_freq: 1,
            #     min_doc_freq: 2,
            #     max_query_terms: 20,
            #     min_word_length: 2,
            #     minimum_should_match: "30%",
            #     boost_terms: 1,
            # }
            mlt_params: {
                hash: {
                    must_keys: [:fields],
                    must_not_keys: [:like],
                    key_values: [
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                array: {
                                    children: {
                                        scalar: {
                                            type: "any_text_or_keyword_without_other_type_field",
                                        },
                                    },
                                },
                            },
                        },
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: {
                                scalar: {
                                    type: "str_or_int_or_bool",
                                },
                            },
                        },
                    ],
                },
            },

            # where: {
            #     status: {
            #         term: "published",
            #     },
            #     user_id: {
            #         terms: [1, 2, 3],
            #     },
            #     price: {
            #         range: {
            #             gte: 1_000,
            #             lte: 5_000,
            #         },
            #     },
            # }
            where: CONDITION_DEFINITIONS,

            # where_not: {
            #     status: {
            #         terms: ["draft", "deleted"],
            #     },
            # }
            where_not: CONDITION_DEFINITIONS,

            # where_or: [
            #     {
            #         status: {
            #             term: "featured",
            #         },
            #     },
            #     {
            #         user_id: {
            #             terms: [1, 2, 3],
            #         },
            #     },
            # ]
            where_or: CONDITION_DEFINITIONS,

            # aggs: {
            #     status: {
            #         size: 20,
            #     },
            #     category: {
            #         size: 50,
            #     },
            # }
            aggs: {
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "any_non_text_without_text_field",
                            },
                            value: {
                                hash: {
                                    must_keys: [:size],
                                    key_values: [
                                        {
                                            key: {
                                                key_name: :size,
                                            },
                                            value: {
                                                scalar: {
                                                    type: "positive_integer",
                                                },
                                            },
                                        },
                                        {
                                            key: {
                                                type: "symbol_key",
                                            },
                                            value: {
                                                scalar: {
                                                    type: "str_or_int_or_bool",
                                                },
                                            },
                                        },
                                    ],
                                },
                            },
                        },
                    ],
                },
            },

            # page: 2
            page: {
                scalar: {
                    type: "positive_integer",
                },
            },

            # per_page: 20
            per_page: {
                scalar: {
                    type: "positive_integer",
                },
            },

            # model_includes: {
            #     Article  => [:user, :tags],
            #     Document => [:author],
            # }
            model_includes: {
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "valid_model",
                            },
                            value: {
                                type: "not_nil",
                            },
                        },
                    ],
                },
            },

            # model_results_where: {
            #     Article  => { status: "published" },
            #     Document => { visible: true },
            # }
            model_results_where: {
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "valid_model",
                            },
                            value: {
                                type: "not_nil",
                            },
                        },
                    ],
                },
            },

            # sort: :updated_at
            #
            # sort: {
            #     updated_at: :desc,
            #     id:         :desc,
            # }
            #
            # Hash形式ではキーの記述順をsortの優先順位として扱う。
            # 値は :asc / :desc のStringまたはSymbolを指定する。
            sort: {
                scalar: {
                    type: "sort_field",
                },
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "sort_field",
                            },
                            value: {
                                scalar: {
                                    type: "str_or_sym",
                                },
                            },
                        },
                    ],
                },
            },

            # highlight: {
            #     fields: [:title, :body],
            # }
            #
            # highlight: {
            #     fields: {
            #         title: {
            #             number_of_fragments: 0,
            #         },
            #         body: {
            #             fragment_size:       200,
            #             number_of_fragments: 3,
            #         },
            #     },
            #     type:                "unified",
            #     require_field_match: false,
            # }
            highlight: {
                hash: {
                    must_keys: [:fields],
                    key_values: [
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                hash: {
                                    key_values: [
                                        {
                                            key: {
                                                type: "any_text_or_keyword_without_other_type_field",
                                            },
                                            value: {
                                                hash: {
                                                    key_values: [
                                                        {
                                                            key: {
                                                                type: "symbol_key",
                                                            },
                                                            value: {
                                                                scalar: {
                                                                    type: "str_or_int_or_bool",
                                                                },
                                                            },
                                                        },
                                                    ],
                                                },
                                            },
                                        },
                                    ],
                                },
                                array: {
                                    children: {
                                        scalar: {
                                            type: "any_text_or_keyword_without_other_type_field",
                                        },
                                    },
                                },
                            },
                        },
                        {
                            key: {
                                key_name: :pre_tags,
                            },
                            value: {
                                array: {
                                    children: {
                                        scalar: {
                                            type: "string",
                                        },
                                    },
                                },
                            },
                        },
                        {
                            key: {
                                key_name: :post_tags,
                            },
                            value: {
                                array: {
                                    children: {
                                        scalar: {
                                            type: "string",
                                        },
                                    },
                                },
                            },
                        },
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: {
                                scalar: {
                                    type: "str_or_int_or_bool",
                                },
                            },
                        },
                    ],
                },
            },

            # dump_body: true
            dump_body: {
                scalar: {
                    type: "boolean",
                },
            },
        }.freeze
    end
end
