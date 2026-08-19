# frozen_string_literal: true

module AreSearch
    class SearchOptionValidator

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
        # node定義に:error_classを指定すると、そのnode以下のArgumentErrorを指定例外へ付け替える。

        # 検索オプション定義の:typeに指定できる名前付き型。
        OPTION_DEFINITION_TYPES = [
            "any",
            "string",
            "symbol",
            "not_nil",
            "boolean",
            "str_or_sym",
            "str_or_int",
            "str_or_int_or_bool",
            "str_or_int_or_float_or_bool",
            "positive_number",
            "positive_integer",
            "page_integer",
            "query_type",
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
            "active_record_relation",
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
                                    error_class: AreSearch::InvalidSearchOption,
                                    scalar: {
                                        type: "str_or_int_or_float_or_bool",
                                    },
                                },
                            },
                            {
                                key: {
                                    key_name: :terms,
                                },
                                value: {
                                    error_class: AreSearch::InvalidSearchOption,
                                    array: {
                                        allow_empty: true,
                                        children: {
                                            scalar: {
                                                type: "str_or_int_or_float_or_bool",
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
                                    error_class: AreSearch::InvalidSearchOption,
                                    hash: {
                                        key_values: [
                                            {
                                                key: {
                                                    type: "symbol_key",
                                                },
                                                value: {
                                                    scalar: {
                                                        type: "str_or_int_or_float_or_bool",
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

        # fieldを使用するaggregationで共通するbody定義。
        # fieldだけを非textフィールドとして検査し、その他はElasticsearchへそのまま渡す。
        AGGREGATION_BODY_DEFINITIONS = {
            hash: {
                must_keys: [:field],
                key_values: [
                    {
                        key: {
                            key_name: :field,
                        },
                        value: {
                            scalar: {
                                type: "any_non_text_without_text_field",
                            },
                        },
                    },
                    {
                        key: {
                            type: "symbol_key",
                        },
                        value: {
                            type: "any",
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

            # runtime_mappings: {
            #     runtime_status: {
            #         type: "keyword",
            #         script: {
            #             source: "emit('published')",
            #         },
            #     },
            # }
            runtime_mappings: {
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "symbol",
                            },
                            value: {
                                hash: {
                                    must_keys: [:type],
                                    key_values: [
                                        {
                                            key: {
                                                key_name: :type,
                                            },
                                            value: {
                                                scalar: {
                                                    type: "str_or_sym",
                                                },
                                            },
                                        },
                                        {
                                            key: {
                                                type: "symbol_key",
                                            },
                                            value: {
                                                type: "any",
                                            },
                                        },
                                    ],
                                },
                            },
                        },
                    ],
                },
            },

            # queries: [
            #     {
            #         query_string: "Rails",
            #         fields: [:title, :body],
            #         query_type: AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
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
                                        error_class: AreSearch::InvalidSearchOption,
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
                                {
                                    key: {
                                        key_name: :query_type,
                                    },
                                    value: {
                                        scalar: {
                                            type: "query_type",
                                        },
                                    },
                                },
                            ],
                        },
                    },
                },
            },

            # mlt: {
            #     fields: [:title, :body],
            #     like: {
            #         instance: article,
            #         index_target: Article.are_search_index_target(:default),
            #     },
            #     min_term_freq: 1,
            #     min_doc_freq: 2,
            #     max_query_terms: 20,
            #     min_word_length: 2,
            #     minimum_should_match: "30%",
            #     boost_terms: 1.5,
            # }
            mlt: {
                hash: {
                    must_keys: [
                        :fields,
                        :like,
                    ],
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
                                key_name: :like,
                            },
                            value: {
                                hash: {
                                    must_keys: [
                                        :instance,
                                        :index_target,
                                    ],
                                    key_values: [
                                        {
                                            key: {
                                                key_name: :instance,
                                            },
                                            value: {
                                                scalar: {
                                                    type: "searchable_instance",
                                                },
                                            },
                                        },
                                        {
                                            key: {
                                                key_name: :index_target,
                                            },
                                            value: {
                                                scalar: {
                                                    type: "index_target",
                                                },
                                            },
                                        },
                                    ],
                                },
                            },
                        },
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: {
                                type: "any",
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

            # model_relations: {
            #     Article  => Article.visible.includes(:user, :tags),
            #     Document => Document.published.includes(:author),
            # }
            model_relations: {
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "valid_model",
                            },
                            value: {
                                scalar: {
                                    type: "active_record_relation",
                                },
                            },
                        },
                    ],
                },
            },

            # page: 2
            page: {
                error_class: AreSearch::InvalidSearchOption,
                scalar: {
                    type: "page_integer",
                },
            },

            # per_page: 20
            per_page: {
                scalar: {
                    type: "page_integer",
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

            # aggs: [:status, :category]
            #
            # aggs: {
            #     status_count: {
            #         terms: {
            #             field: :status,
            #             size: 20,
            #         },
            #     },
            #     score_ranges: {
            #         range: {
            #             field: :score,
            #             ranges: [
            #                 { to: 1.0 },
            #                 { from: 1.0, to: 2.0 },
            #                 { from: 2.0 },
            #             ],
            #         },
            #     },
            # }
            aggs: {
                array: {
                    children: {
                        scalar: {
                            type: "any_non_text_without_text_field",
                        },
                    },
                },
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: {
                                hash: {
                                    item_count: 1,
                                    key_values: [
                                        {
                                            key: {
                                                type: "symbol_key",
                                            },
                                            value: AGGREGATION_BODY_DEFINITIONS,
                                        },
                                    ],
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
                                                type: "any",
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
                                type: "symbol_key",
                            },
                            value: {
                                type: "any",
                            },
                        },
                    ],
                },
            },

            # response: {
            #     source: [
            #         "title",
            #         "payload.*",
            #     ],
            #     fields: [
            #         "runtime_status",
            #     ],
            #     stored_fields: [
            #         "body",
            #     ],
            #     docvalue_fields: [
            #         "status",
            #     ],
            # }
            response: {
                hash: {
                    key_values: [
                        {
                            key: {
                                key_name: :source,
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
                                key_name: :fields,
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
                                key_name: :stored_fields,
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
                                key_name: :docvalue_fields,
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
                    ],
                },
            },

            # build_model_bool: true
            build_model_bool: {
                scalar: {
                    type: "boolean",
                },
            },

            # enable_runtime_mappings: true
            enable_runtime_mappings: {
                scalar: {
                    type: "boolean",
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
