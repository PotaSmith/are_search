# frozen_string_literal: true

# 検索オプション定義の作成ガイド。
#
# このファイルには、SearchOptionValidator が解釈する定義形式と、
# AreSearch::Searcher.search が受け付ける検索オプションの定義をまとめる。
#
# 新しい検索オプションを追加する場合は、まず OPTION_DEFINITIONS に
# 最小の定義を追加し、必要になった構造だけを :items で内側へ掘り下げる。
#
#
# 1. 最小の検索オプションを定義する
# ================================================================================
#
# OPTION_DEFINITIONS は、検索オプション名をキーにした Hash。
# オプション名は Symbol で指定する。
#
# 各オプションの値は、許可する形式を並べた Array にする。
# 最も単純な String オプションは次のように定義する。
#
#     OPTION_DEFINITIONS = {
#         query_string: [
#             {
#                 item_type: String,
#             },
#         ],
#     }.freeze
#
# この定義では、次の入力を許可する。
#
#     query_string: "Rails"
#
# :item_type に Class を指定すると、instance_of? で型を検査する。
# 継承先も含めて判定する is_a? ではない。
#
# 定義ノードは必ず Hash で記述し、:item_type を必須とする。
# 定義ノードで使用できるキーは SearchOptionValidator::ITEM_DEFINITION_KEYS に列挙する。
#
#
# 2. 複数の入力形式を許可する
# ================================================================================
#
# 1つのオプションに複数の形式を許可する場合は、候補定義を Array に並べる。
# 候補は先頭から順に照合し、最初に一致した定義を使用する。
#
#     fields: [
#         {
#             item_type: Array,
#         },
#         {
#             item_type: Hash,
#         },
#     ],
#
# この定義では、fields に Array または Hash を指定できる。
# :items が無いため、Array の要素と Hash の内容までは検査しない。
# Hash と Array は、入力を変更しないよう再帰的に複製して返す。
#
#
# 3. 名前付き item_type を使用する
# ================================================================================
#
# Class だけでは表せない条件は、:item_type に SearchOptionValidator::NAMED_ITEM_TYPES の名前を
# String で指定する。
#
#     page: [
#         {
#             item_type: "positive_integer",
#         },
#     ],
#
# この定義では、0より大きい Integer だけを許可する。
# 名前付き item_type は、型検査だけでなく後続処理向けの正規化も行う。
#
# 使用できる名前と結果は次の通り。
#
#     any
#         値の型を制限しない。
#         nil も許可する。
#         Hash / Array は再帰的に複製して返す。
#
#     not_nil
#         値の型を制限せず、nil だけを拒否する。
#         Hash / Array は再帰的に複製して返す。
#
#     boolean
#         true または false だけを許可し、そのまま返す。
#
#     str_or_sym
#         String または Symbol の単一値だけを許可し、そのまま返す。
#
#     str_or_int
#         String または Integer の単一値だけを許可し、そのまま返す。
#
#     str_or_int_or_bool
#         String、Integer、true、false の単一値だけを許可し、そのまま返す。
#
#     positive_number
#         0より大きい Integer または Float を許可し、そのまま返す。
#
#     positive_integer
#         0より大きい Integer を許可し、そのまま返す。
#
#     search_field
#         String または Symbol のフィールド指定を許可する。
#         title^2.5 のような boost 表記を分解し、次の Hash へ正規化する。
#
#             {
#                 field: :title,
#                 boost: 2.5,
#             }
#
#         boost を指定しない場合、:boost は nil になる。
#
#     any_valid_search_field
#         search_field と同じ検査と正規化を行い、field を
#         context[:any_fields] と照合する。
#         1つ以上のtargetに存在すれば許可する。
#
#     all_valid_search_field
#         search_field と同じ検査と正規化を行い、field を
#         context[:all_fields] と照合する。
#         すべてのtargetに存在する場合だけ許可する。
#
#     any_text_search_without_non_text_fields
#         search_field と同じ検査と正規化を行い、field を
#         context[:any_text_without_non_text_fields] と照合する。
#
#     all_valid_text_search_field
#         search_field と同じ検査と正規化を行い、field を
#         context[:all_valid_text_fields] と照合する。
#
#     field_name
#         空ではない String または Symbol を許可し、Symbolへ正規化する。
#         boost 表記は許可しない。
#
#     any_valid_field
#         field_name と同じ検査と正規化を行い、
#         context[:any_fields] と照合する。
#         1つ以上のtargetに存在すれば許可する。
#
#     all_valid_field
#         field_name と同じ検査と正規化を行い、
#         context[:all_fields] と照合する。
#         すべてのtargetに存在する場合だけ許可する。
#
#     any_text_without_non_text_fields
#         field_name と同じ検査と正規化を行い、
#         context[:any_text_without_non_text_fields] と照合する。
#
#     all_valid_text_field
#         field_name と同じ検査と正規化を行い、
#         context[:all_valid_text_fields] と照合する。
#
#     any_text_or_keyword_without_other_type_fields
#         field_name と同じ検査と正規化を行い、
#         context[:any_text_or_keyword_without_other_type_fields] と照合する。
#
#     all_valid_text_or_keyword_field
#         field_name と同じ検査と正規化を行い、
#         context[:all_valid_text_or_keyword_fields] と照合する。
#
#     any_non_text_without_text_fields
#         field_name と同じ検査と正規化を行い、
#         context[:any_non_text_without_text_fields] と照合する。
#
#     all_valid_non_text_field
#         field_name と同じ検査と正規化を行い、
#         context[:all_valid_non_text_fields] と照合する。
#
#     model_class
#         Class の値だけを許可し、そのまま返す。
#
#     valid_model
#         model_class の検査に加え、context[:models] に含まれるClassだけを許可する。
#
#     searchable_instance
#         value.class が AreSearch::Searchable を include している
#         インスタンスだけを許可する。
#
#     index_target
#         AreSearch::IndexTarget の直接のインスタンスだけを許可する。
#
#
# 4. Array の要素を定義する
# ================================================================================
#
# Array の各要素を検査する場合は、:items に要素の候補定義を Array で指定する。
#
#     fields: [
#         {
#             item_type: Array,
#             items: [
#                 {
#                     item_type: "any_text_or_keyword_without_other_type_fields",
#                 },
#             ],
#         },
#     ],
#
# この定義では、Array の全要素を any_text_or_keyword_without_other_type_fields として検査する。
# :items に複数の定義を並べると、各要素はそのいずれかに一致すればよい。
#
# Array は標準では1件以上を必要とする。
# 空配列を許可する場合だけ :allow_empty => true を指定する。
#
#     terms: [
#         {
#             item_type: Array,
#             allow_empty: true,
#             items: [
#                 {
#                     item_type: "str_or_int_or_bool",
#                 },
#             ],
#         },
#     ],
#
# :allow_empty は :item_type が Array の定義にだけ指定できる。
# 指定値は true だけを許可する。
#
#
# 5. Hash のキーと値を定義する
# ================================================================================
#
# Hash の内容を検査する場合は、:items にキーと値の候補定義を Array で指定する。
# :items に Hash を指定する形式は使用しない。
#
#     query: [
#         {
#             item_type: Hash,
#             must_keys: [:query_string, :fields],
#             items: [
#                 {
#                     key_name: :query_string,
#                     item_type: String,
#                 },
#                 {
#                     key_name: :fields,
#                     item_type: Array,
#                     items: [
#                         {
#                             item_type: "any_valid_field",
#                         },
#                     ],
#                 },
#             ],
#         },
#     ],
#
# 各候補定義には、:key_name または :key_type のどちらか一方だけを指定する。
#
# :key_name
#     特定の固定キーだけに適用する候補。
#     キー名は Symbol で指定する。
#
#     {
#         key_name: :fields,
#         item_type: Array,
#     }
#
# :key_type
#     条件に合う任意のキーへ適用する候補。
#     SearchOptionValidator::NAMED_KEY_TYPES の名前を String で指定する。
#
#     {
#         key_type: "any_valid_field",
#         item_type: "positive_number",
#     }
#
# 同じ :key_name を持つ候補は複数定義できる。
# これにより、特定キーの値へ複数の形式を許可できる。
#
#     items: [
#         {
#             key_name: :fields,
#             item_type: Array,
#         },
#         {
#             key_name: :fields,
#             item_type: Hash,
#         },
#     ]
#
# 入力キーと一致する :key_name 候補がある場合は、その候補だけを使用する。
# 値が一致しなくても、後ろの汎用 :key_type 候補へはフォールバックしない。
#
# Hash は1件以上を必要とする。
# 空の Hash を許可する指定はない。
# 入力の String キーは、各候補のキー検査で必要に応じて Symbolへ正規化する。
# String と Symbol の両方で同じキーを指定した場合は、重複として拒否する。
#
#
# 6. Hash の件数と必須・禁止キーを指定する
# ================================================================================
#
# Hash の要素数を固定する場合は :item_count を指定する。
#
#     {
#         item_type: Hash,
#         item_count: 1,
#         items: [
#             {
#                 key_type: "any_valid_field",
#                 item_type: Hash,
#             },
#         ],
#     }
#
# :item_count は0以上の Integerで、:item_type が Hash の場合だけ指定できる。
#
# 必ず含める固定キーがある場合は :must_keys を指定する。
#
#     {
#         item_type: Hash,
#         must_keys: [:fields],
#         items: [
#             {
#                 key_name: :fields,
#                 item_type: Array,
#             },
#             {
#                 key_type: "symbol_key",
#                 item_type: "any",
#             },
#         ],
#     }
#
# :must_keys は重複のない Symbol の Array で、1件以上を指定する。
#
# 指定を禁止する固定キーがある場合は :must_not_keys を指定する。
#
#     {
#         item_type: Hash,
#         must_keys:     [:fields],
#         must_not_keys: [:like],
#         items: [
#             {
#                 key_name: :fields,
#                 item_type: Array,
#             },
#             {
#                 key_type: "symbol_key",
#                 item_type: "str_or_int_or_bool",
#             },
#         ],
#     }
#
# :must_not_keys も重複のない Symbol の Array で、1件以上を指定する。
# :must_keys と :must_not_keys に同じキーは指定できない。
# StringキーもSymbolへ正規化してから必須・禁止を判定する。
#
#
# 7. key_type を選ぶ
# ================================================================================
#
# key_type は Hash のキーを検査し、正規化したキーを返す。
# 使用できる名前は次の通り。
#
#     symbol_key
#         Symbol はそのまま許可する。
#         空ではない String は Symbolへ正規化する。
#
#     field_name
#         SearchOptionValidator::NAMED_ITEM_TYPES の field_name と同じ。
#
#     sort_field
#         SearchOptionValidator::NAMED_ITEM_TYPES の sort_field と同じ。
#         通常フィールドは全targetで定義された非textフィールドだけを許可する。
#         Elasticsearchの特別なsort値として :_score と :_doc も許可する。
#
#     any_valid_field
#         SearchOptionValidator::NAMED_ITEM_TYPES の any_valid_field と同じ。
#
#     all_valid_field
#         SearchOptionValidator::NAMED_ITEM_TYPES の all_valid_field と同じ。
#
#     any_text_without_non_text_fields
#         SearchOptionValidator::NAMED_ITEM_TYPES の any_text_without_non_text_fields と同じ。
#
#     all_valid_text_field
#         SearchOptionValidator::NAMED_ITEM_TYPES の all_valid_text_field と同じ。
#
#     any_text_or_keyword_without_other_type_fields
#         SearchOptionValidator::NAMED_ITEM_TYPES の any_text_or_keyword_without_other_type_fields と同じ。
#
#     all_valid_text_or_keyword_field
#         SearchOptionValidator::NAMED_ITEM_TYPES の all_valid_text_or_keyword_field と同じ。
#
#     any_non_text_without_text_fields
#         SearchOptionValidator::NAMED_ITEM_TYPES の any_non_text_without_text_fields と同じ。
#
#     all_valid_non_text_field
#         SearchOptionValidator::NAMED_ITEM_TYPES の all_valid_non_text_field と同じ。
#
#     model_class
#         SearchOptionValidator::NAMED_ITEM_TYPES の model_class と同じ。
#
#     valid_model
#         SearchOptionValidator::NAMED_ITEM_TYPES の valid_model と同じ。
#
#
# 8. context を必要とする定義
# ================================================================================
#
# フィールド一覧を参照する item_type / key_type と valid_model は、
# SearchOptionValidator.validate の context を参照する。
# context は SearchOptionValidator の外側でtargetごとのmappingsから収集し、
# 次の形式で渡す。
#
#     {
#         models: [Article, Comment],
#         any_fields: [:title, :status, :published_at],
#         all_fields: [:title],
#         any_text_without_non_text_fields: [:title, :body],
#         all_valid_text_fields: [:title],
#         any_text_or_keyword_without_other_type_fields: [:title, :body, :status],
#         all_valid_text_or_keyword_fields: [:title],
#         any_non_text_without_text_fields: [:status, :published_at],
#         all_valid_non_text_fields: [],
#     }
#
#     :models
#         検索対象モデルClassのArray。
#
#     :any_fields
#         1つ以上のtargetに存在するフィールド名の和集合。
#         同名フィールドの型は判定しない。
#
#     :all_fields
#         すべてのtargetに存在するフィールド名の積集合。
#         同名フィールドの型は判定しない。
#
#     :any_text_without_non_text_fields
#         1つ以上のtargetでtext型として定義され、ほかのtargetで
#         同名フィールドが非text型として定義されていないフィールド。
#         同名フィールドが未定義のtargetは許容する。
#
#     :all_valid_text_fields
#         すべてのtargetでtext型として定義されているフィールド。
#
#     :any_text_or_keyword_without_other_type_fields
#         1つ以上のtargetでtext型またはkeyword型として定義され、
#         ほかのtargetで同名フィールドが別の型として定義されていないフィールド。
#         同名フィールドが未定義のtargetは許容する。
#
#     :all_valid_text_or_keyword_fields
#         すべてのtargetでtext型またはkeyword型として定義されているフィールド。
#
#     :any_non_text_without_text_fields
#         1つ以上のtargetで非text型として定義され、ほかのtargetで
#         同名フィールドがtext型として定義されていないフィールド。
#         同名フィールドが未定義のtargetは許容する。
#
#     :all_valid_non_text_fields
#         すべてのtargetで非text型として定義されているフィールド。
#
# any_*_without_*_fields は単純な型別和集合ではない。
# 許容型の和集合から不許容型の和集合を除外し、同名フィールドの型混在を拒否する。
# all_valid_* はtargetごとの型別フィールド一覧の積集合を使用する。
#
# contextを参照するフィールド型は、フィールド名の表記に関係なく
# context の対応するフィールド一覧と必ず照合する。
# mappings の properties / runtime 直下に存在しないフィールド名や、
# ドット・ワイルドカード等を使った Elasticsearch 固有表記は許可しない。
# それらが必要な検索は raw_body で明示的に組み立てる。
#
#
# 9. nil の扱い
# ================================================================================
#
# OPTION_DEFINITIONS 全体を使って検索オプションを検査する場合、
# 値が nil のオプションは :item_type を検査せず、nil のまま結果へ残す。
#
#     {
#         fields: nil,
#     }
#
# nil 自体を禁止する場合は、この定義ファイルだけでは完結しない。
# SearchOptionValidator.validate_options の nil 処理も変更する。
#
#
# 10. 定義を追加した後の確認
# ================================================================================
#
# OPTION_DEFINITIONS を変更したら、定義形式の検査を実行する。
#
#     AreSearch::SearchOptionDefinitionChecker
#         .validate_option_definitions!
#
# SearchOptionDefinitionChecker は、主に次を確認する。
#
#     OPTION_DEFINITIONS のトップレベル形式
#     定義ノードの :item_type
#     未知の定義キー
#     :items の Array形式
#     :key_name / :key_type の位置と排他
#     :item_count / :allow_empty / :must_keys / :must_not_keys の使用条件
#     SearchOptionValidator::NAMED_ITEM_TYPES / SearchOptionValidator::NAMED_KEY_TYPES に存在する名前か
#
# 名前付き型を追加または変更する場合は、次を同時に更新する。
#
#     item_type
#         SearchOptionValidator::NAMED_ITEM_TYPES
#         SearchOptionValidator.validate_named_item_type の case 分岐
#
#     key_type
#         SearchOptionValidator::NAMED_KEY_TYPES
#         SearchOptionValidator.normalize_key_type の case 分岐
#
#     共通
#         SearchOptionDefinitionChecker の検査
#         SearchOptionValidator のspec
#         SearchOptionDefinitionChecker のspec
#
# OPTION_DEFINITIONS は入力形式だけではなく、正規化後に後続処理へ渡す形式も決める。
# 定義を変更する場合は、入力を受け付けるかだけでなく、正規化結果が
# QueryBuilder / BodyBuilder の期待する形になっているかも確認する。

module AreSearch
    module Searcher
        extend self

        # CONDITION_FIELD_DEFINITION が表す1フィールド分の指定例。
        #
        # status: {
        #     term: "published",
        # }
        #
        # user_id: {
        #     terms: [1, 2, 3],
        # }
        #
        # price: {
        #     range: {
        #         gte: 1_000,
        #         lte: 5_000,
        #     },
        # }
        CONDITION_FIELD_DEFINITION = [
            {
                key_type: "any_non_text_without_text_fields",
                item_type: Hash,
                item_count: 1,
                items: [
                    {
                        key_name: :term,
                        item_type: "str_or_int_or_bool",
                    },
                    {
                        key_name: :terms,
                        item_type: Array,
                        allow_empty: true,
                        items: [
                            {
                                item_type: "str_or_int_or_bool",
                            },
                        ],
                    },
                    {
                        key_name: :range,
                        item_type: Hash,
                        items: [
                            {
                                key_type: "symbol_key",
                                item_type: "str_or_int_or_bool",
                            },
                        ],
                    },
                ],
            },
        ].freeze

        # CONDITION_DEFINITIONS が表す指定例。
        #
        # {
        #     status: {
        #         term: "published",
        #     },
        #     user_id: {
        #         terms: [1, 2, 3],
        #     },
        # }
        #
        # [
        #     {
        #         status: {
        #             term: "published",
        #         },
        #     },
        #     {
        #         user_id: {
        #             terms: [1, 2, 3],
        #         },
        #     },
        # ]
        CONDITION_DEFINITIONS = [
            {
                item_type: Hash,
                items: CONDITION_FIELD_DEFINITION,
            },
            {
                item_type: Array,
                items: [
                    {
                        item_type: Hash,
                        items: CONDITION_FIELD_DEFINITION,
                    },
                ],
            },
        ].freeze

        FIELDS_DEFINITIONS = [
            {
                item_type: Array,
                items: [
                    {
                        item_type: "any_text_without_non_text_fields",
                    },
                ],
            },
            {
                item_type: Hash,
                items: [
                    {
                        key_type: "any_text_without_non_text_fields",
                        item_type: "positive_number",
                    },
                ],
            },
        ].freeze

        OPTION_DEFINITIONS = {
            # raw_body: {
            #     query: {
            #         match_all: {},
            #     },
            # }
            raw_body: [
                {
                    item_type: Hash,
                },
            ],
            # build_model_bool: true
            build_model_bool: [
                {
                    item_type: "boolean",
                },
            ],
            # query_string: "Rails"
            query_string: [
                {
                    item_type: String,
                },
            ],
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
            queries: [
                {
                    item_type: Array,
                    items: [
                        {
                            item_type: Hash,
                            must_keys: [:query_string, :fields],
                            items: [
                                {
                                    key_name: :query_string,
                                    item_type: String,
                                },
                                {
                                    key_name: :fields,
                                    item_type: Array,
                                    items: [
                                        {
                                            item_type: "any_text_without_non_text_fields",
                                        },
                                    ],
                                },
                                {
                                    key_name: :fields,
                                    item_type: Hash,
                                    items: [
                                        {
                                            key_type: "any_text_without_non_text_fields",
                                            item_type: "positive_number",
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
            # mlt_instance: article
            mlt_instance: [
                {
                    item_type: "searchable_instance",
                },
            ],
            # mlt_index_target: Article.are_search_index_target(:default)
            mlt_index_target: [
                {
                    item_type: "index_target",
                },
            ],
            # mlt_params: {
            #     fields: [:title, :body],
            #     min_term_freq: 1,
            #     min_doc_freq: 2,
            #     max_query_terms: 20,
            #     min_word_length: 2,
            #     minimum_should_match: "30%",
            #     boost_terms: 1,
            # }
            mlt_params: [
                {
                    item_type: Hash,
                    must_keys: [:fields],
                    must_not_keys: [:like],
                    items: [
                        {
                            key_name: :fields,
                            item_type: Array,
                            items: [
                                {
                                    item_type: "any_text_or_keyword_without_other_type_fields",
                                },
                            ],
                        },
                        {
                            key_type: "symbol_key",
                            item_type: "str_or_int_or_bool",
                        },
                    ],
                },
            ],
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
            aggs: [
                {
                    item_type: Hash,
                    items: [
                        {
                            key_type: "any_non_text_without_text_fields",
                            item_type: Hash,
                            must_keys: [:size],
                            items: [
                                {
                                    key_name: :size,
                                    item_type: "positive_integer",
                                },
                                {
                                    key_type: "symbol_key",
                                    item_type: "str_or_int_or_bool",
                                },
                            ],
                        },
                    ],
                },
            ],
            # page: 2
            page: [
                {
                    item_type: "positive_integer",
                },
            ],
            # per_page: 20
            per_page: [
                {
                    item_type: "positive_integer",
                },
            ],
            # model_includes: {
            #     Article  => [:user, :tags],
            #     Document => [:author],
            # }
            model_includes: [
                {
                    item_type: Hash,
                    items: [
                        {
                            key_type: "valid_model",
                            item_type: "not_nil",
                        },
                    ],
                },
            ],
            # model_results_where: {
            #     Article  => { status: "published" },
            #     Document => { visible: true },
            # }
            model_results_where: [
                {
                    item_type: Hash,
                    items: [
                        {
                            key_type: "valid_model",
                            item_type: "not_nil",
                        },
                    ],
                },
            ],
            # sort: :updated_at
            #
            # sort: {
            #     updated_at: :desc,
            #     id:         :desc,
            # }
            #
            # Hash形式ではキーの記述順をsortの優先順位として扱う。
            # 値は :asc / :desc のStringまたはSymbolを指定する。
            sort: [
                {
                    item_type: "sort_field",
                },
                {
                    item_type: Hash,
                    items: [
                        {
                            key_type: "sort_field",
                            item_type: "str_or_sym",
                        },
                    ],
                },
            ],
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
            highlight: [
                {
                    item_type: Hash,
                    must_keys: [:fields],
                    items: [
                        {
                            key_name: :fields,
                            item_type: Hash,
                            items: [
                                {
                                    key_type: "any_text_or_keyword_without_other_type_fields",
                                    item_type: Hash,
                                    items: [
                                        {
                                            key_type: "symbol_key",
                                            item_type: "str_or_int_or_bool",
                                        },
                                    ],
                                },
                            ],
                        },
                        {
                            key_name: :fields,
                            item_type: Array,
                            items: [
                                {
                                    item_type: "any_text_or_keyword_without_other_type_fields",
                                },
                            ],
                        },
                        {
                            key_type: "symbol_key",
                            item_type: "str_or_int_or_bool",
                        },
                    ],
                },
            ],
            # dump_body: true
            dump_body: [
                {
                    item_type: "boolean",
                },
            ],
        }.freeze
    end
end
