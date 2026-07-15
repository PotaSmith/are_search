# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchOptionValidator do
    def build_context(**overrides)
        context = {
            models: [],
            any_fields: [],
            all_fields: [],
            any_text_without_non_text_fields: [],
            all_valid_text_fields: [],
            any_text_or_keyword_without_other_type_fields: [],
            all_valid_text_or_keyword_fields: [],
            any_non_text_without_text_fields: [],
            all_valid_non_text_fields: [],
        }

        context.merge(overrides)
    end

    # 単一nodeをトップレベルオプションとして検査し、nodeの結果だけを返す。
    def validate_node(value, definition, context: nil)
        result = described_class.validate(
            {
                value: value,
            },
            {
                value: definition,
            },
            context,
        )

        result[:value]
    end

    # scalar node用の定義を作る。
    def scalar_definition(type)
        {
            scalar: {
                type: type,
            },
        }
    end

    describe ".validate のオプション定義Map処理" do
        it "Symbolのオプション名を扱い、nilをそのまま残す" do
            definitions = {
                query_string: {
                    type: "any",
                },
            }

            result = described_class.validate(
                {
                    query_string: nil,
                },
                definitions,
                nil,
            )

            expect(result).to eq(
                query_string: nil,
            )
        end

        it "typeというオプション名も定義Mapとして扱う" do
            definitions = {
                type: scalar_definition("positive_integer"),
            }

            result = described_class.validate(
                {
                    type: 1,
                },
                definitions,
                nil,
            )

            expect(result).to eq(
                type: 1,
            )
        end

        it "未知のオプションを拒否する" do
            definitions = {
                page: scalar_definition("positive_integer"),
            }

            expect do
                described_class.validate(
                    {
                        unknown: 1,
                    },
                    definitions,
                    nil,
                )
            end.to raise_error(
                ArgumentError,
                "未知の検索オプションが指定されています: unknown",
            )
        end

        it "Stringのオプション名をSymbolへ変換せず拒否する" do
            definitions = {
                page: scalar_definition("positive_integer"),
            }

            expect do
                described_class.validate(
                    {
                        "page" => 1,
                    },
                    definitions,
                    nil,
                )
            end.to raise_error(
                ArgumentError,
                'opts[:page] は Symbol で指定してください: "page"',
            )
        end
    end

    describe ".validate の候補定義処理" do
        it "nodeの実体型に対応する定義を選択する" do
            definition = {
                scalar: {
                    type: "string",
                },
                array: {
                    children: scalar_definition("str_or_sym"),
                },
            }

            scalar_result = validate_node("title", definition)
            array_result = validate_node([:title, "body"], definition)

            expect(scalar_result).to eq("title")
            expect(array_result).to eq([:title, "body"])
        end

        it "対応するnode_type定義が無ければ拒否する" do
            expect do
                validate_node(
                    "title",
                    {},
                )
            end.to raise_error(
                ArgumentError,
                /node_type :scalar は定義されていません/,
            )

            expect do
                validate_node(
                    :title,
                    {
                        array: {
                            children: scalar_definition("string"),
                        },
                    },
                )
            end.to raise_error(
                ArgumentError,
                /node_type :scalar は定義されていません/,
            )
        end
    end

    describe ".validate の名前付きtype処理" do
        it "anyはHashとArrayを再帰的に複製する" do
            value = {
                "query" => [
                    {
                        "match_all" => {},
                    },
                ],
            }

            result = validate_node(
                value,
                {
                    type: "any",
                },
            )

            expect(result).to eq(value)
            expect(result).not_to equal(value)
            expect(result["query"]).not_to equal(value["query"])
            expect(result["query"][0]).not_to equal(value["query"][0])
        end

        it "anyはnilもそのまま許可する" do
            result = validate_node(
                nil,
                {
                    type: "any",
                },
            )

            expect(result).to eq(nil)
        end

        it "not_nilは型を限定せずnilだけを拒否する" do
            value = {
                "includes" => [:user, :tags],
            }
            definition = {
                type: "not_nil",
            }

            result = validate_node(value, definition)

            expect(result).to eq(value)
            expect(result).not_to equal(value)
            expect(result["includes"]).not_to equal(value["includes"])
            expect(validate_node(false, definition)).to eq(false)

            expect do
                validate_node(nil, definition)
            end.to raise_error(ArgumentError)
        end

        it "boolean、文字列系、数値系の独自型を検査する" do
            expect(
                validate_node(
                    false,
                    scalar_definition("boolean"),
                ),
            ).to eq(false)

            expect(
                validate_node(
                    :desc,
                    scalar_definition("str_or_sym"),
                ),
            ).to eq(:desc)

            expect(
                validate_node(
                    10,
                    scalar_definition("str_or_int"),
                ),
            ).to eq(10)

            expect(
                validate_node(
                    true,
                    scalar_definition("str_or_int_or_bool"),
                ),
            ).to eq(true)

            expect(
                validate_node(
                    2.5,
                    scalar_definition("positive_number"),
                ),
            ).to eq(2.5)

            expect(
                validate_node(
                    2,
                    scalar_definition("positive_integer"),
                ),
            ).to eq(2)
        end

        it "独自型が許可しない値を拒否する" do
            invalid_values = [
                ["boolean", 1, /true または false/],
                ["str_or_sym", 1, /String または Symbol/],
                ["str_or_int", false, /String または Integer/],
                ["str_or_int_or_bool", 1.5, /String、Integer、true、false/],
                ["positive_number", 0, /正の数/],
                ["positive_integer", 1.5, /正の整数/],
            ]

            invalid_values.each do |definition_type, value, expected_message|
                expect do
                    validate_node(
                        value,
                        scalar_definition(definition_type),
                    )
                end.to raise_error(ArgumentError, expected_message)
            end
        end

        it "symbol_keyは形式に合うSymbolだけを許可する" do
            expect(
                validate_node(
                    :title,
                    scalar_definition("symbol_key"),
                ),
            ).to eq(:title)

            ["title", :_title, :title_, :"title.keyword", 1].each do |value|
                expect do
                    validate_node(
                        value,
                        scalar_definition("symbol_key"),
                    )
                end.to raise_error(ArgumentError)
            end
        end
    end

    describe ".validate のArray処理" do
        it "各要素をchildren定義で検査する" do
            definition = {
                array: {
                    children: scalar_definition("str_or_sym"),
                },
            }

            result = validate_node(
                ["title", :body],
                definition,
            )

            expect(result).to eq(["title", :body])
        end

        it "標準では空配列を拒否し、allow_empty指定時だけ許可する" do
            expect do
                validate_node(
                    [],
                    {
                        array: {
                            children: scalar_definition("positive_integer"),
                        },
                    },
                )
            end.to raise_error(ArgumentError)

            result = validate_node(
                [],
                {
                    array: {
                        allow_empty: true,
                        children: scalar_definition("positive_integer"),
                    },
                },
            )

            expect(result).to eq([])
        end
    end

    describe ".validate のkey_name Hash処理" do
        it "必須の固定キーを検査する" do
            definition = {
                hash: {
                    must_keys: [:query_string, :fields],
                    key_values: [
                        {
                            key: {
                                key_name: :query_string,
                            },
                            value: scalar_definition("string"),
                        },
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                array: {
                                    children: scalar_definition("str_or_sym"),
                                },
                            },
                        },
                    ],
                },
            }

            result = validate_node(
                {
                    fields: [:title],
                    query_string: "Rails",
                },
                definition,
            )

            expect(result).to eq(
                fields: [:title],
                query_string: "Rails",
            )
        end

        it "同じkey_nameのvalueへ複数のnode_typeを定義できる" do
            definition = {
                hash: {
                    must_keys: [:fields],
                    key_values: [
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                array: {
                                    children: scalar_definition("str_or_sym"),
                                },
                                hash: {
                                    key_values: [
                                        {
                                            key: {
                                                type: "symbol_key",
                                            },
                                            value: scalar_definition("positive_number"),
                                        },
                                    ],
                                },
                            },
                        },
                    ],
                },
            }

            array_result = validate_node(
                {
                    fields: [:title],
                },
                definition,
            )
            hash_result = validate_node(
                {
                    fields: {
                        title: 2.0,
                    },
                },
                definition,
            )

            expect(array_result).to eq(
                fields: [:title],
            )
            expect(hash_result).to eq(
                fields: {
                    title: 2.0,
                },
            )
        end

        it "固定キー候補にもtype候補にも一致しないキーを未知のキーとして拒否する" do
            definition = {
                hash: {
                    item_count: 1,
                    key_values: [
                        {
                            key: {
                                key_name: :term,
                            },
                            value: scalar_definition("str_or_int_or_bool"),
                        },
                        {
                            key: {
                                type: "all_valid_non_text_field",
                            },
                            value: scalar_definition("positive_integer"),
                        },
                    ],
                },
            }
            context = build_context(
                all_valid_non_text_fields: [:status],
            )

            expect do
                validate_node(
                    {
                        foo: 1,
                    },
                    definition,
                    context: context,
                )
            end.to raise_error(
                ArgumentError,
                "opts[:value] に未知のキーがあります: foo",
            )
        end

        it "must_keysに指定したキーが無ければ拒否する" do
            definition = {
                hash: {
                    must_keys: [:fields],
                    key_values: [
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                array: {
                                    allow_empty: true,
                                    children: scalar_definition("str_or_sym"),
                                },
                            },
                        },
                        {
                            key: {
                                key_name: :type,
                            },
                            value: scalar_definition("string"),
                        },
                    ],
                },
            }

            expect do
                validate_node(
                    {
                        type: "unified",
                    },
                    definition,
                )
            end.to raise_error(
                ArgumentError,
                "opts[:value] に必要なキーがありません: [:fields]",
            )
        end

        it "must_not_keysに指定したキーを拒否する" do
            definition = {
                hash: {
                    must_not_keys: [:like],
                    key_values: [
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: scalar_definition("str_or_int_or_bool"),
                        },
                    ],
                },
            }

            expect do
                validate_node(
                    {
                        like: "other document",
                    },
                    definition,
                )
            end.to raise_error(
                ArgumentError,
                "opts[:value] に指定できないキーがあります: [:like]",
            )

            result = validate_node(
                {
                    min_term_freq: 1,
                },
                definition,
            )

            expect(result).to eq(
                min_term_freq: 1,
            )
        end

        it "定義されていないキーを拒否する" do
            definition = {
                hash: {
                    must_keys: [:fields],
                    key_values: [
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                array: {
                                    allow_empty: true,
                                    children: scalar_definition("str_or_sym"),
                                },
                            },
                        },
                    ],
                },
            }

            expect do
                validate_node(
                    {
                        fields: [],
                        unknown: true,
                    },
                    definition,
                )
            end.to raise_error(
                ArgumentError,
                "opts[:value] に未知のキーがあります: unknown",
            )
        end

    end

    describe ".validate の可変キーHash処理" do
        it "key_nameを優先し、typeで残りのキーを検査する" do
            definition = {
                hash: {
                    must_keys: [:fields],
                    key_values: [
                        {
                            key: {
                                key_name: :fields,
                            },
                            value: {
                                array: {
                                    children: scalar_definition("str_or_sym"),
                                },
                            },
                        },
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: scalar_definition("str_or_int_or_bool"),
                        },
                    ],
                },
            }

            result = validate_node(
                {
                    fields: [:title],
                    type: "unified",
                },
                definition,
            )

            expect(result).to eq(
                fields: [:title],
                type: "unified",
            )
        end

        it "item_countとmust_keysを検査する" do
            count_definition = {
                hash: {
                    item_count: 1,
                    key_values: [
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: scalar_definition("positive_integer"),
                        },
                    ],
                },
            }

            expect do
                validate_node(
                    {
                        one: 1,
                        two: 2,
                    },
                    count_definition,
                )
            end.to raise_error(
                ArgumentError,
                /opts\[:value\] は 1 件で指定してください/,
            )

            required_definition = {
                hash: {
                    must_keys: [:fields],
                    key_values: [
                        {
                            key: {
                                type: "symbol_key",
                            },
                            value: scalar_definition("positive_integer"),
                        },
                    ],
                },
            }

            expect do
                validate_node(
                    {
                        size: 10,
                    },
                    required_definition,
                )
            end.to raise_error(
                ArgumentError,
                "opts[:value] に必要なキーがありません: [:fields]",
            )
        end
    end

    describe ".validate のcontext参照型処理" do
        let(:article_model) do
            Class.new
        end

        let(:context) do
            build_context(
                models: [article_model],
                any_fields: [:title, :status, :article_only],
                all_fields: [:title, :status],
                any_text_without_non_text_fields: [:title, :article_only],
                all_valid_text_fields: [:title],
                any_text_or_keyword_without_other_type_fields: [:title, :status, :article_only],
                all_valid_text_or_keyword_fields: [:title, :status],
                any_non_text_without_text_fields: [:status],
                all_valid_non_text_fields: [:status],
            )
        end

        it "anyとallのフィールド集合をそれぞれ参照する" do
            any_result = validate_node(
                :article_only,
                scalar_definition("any_valid_field"),
                context: context,
            )

            expect(any_result).to eq(:article_only)

            expect do
                validate_node(
                    :article_only,
                    scalar_definition("all_valid_field"),
                    context: context,
                )
            end.to raise_error(ArgumentError)
        end

        it "text、textまたはkeyword、非textの集合を区別する" do
            text_result = validate_node(
                :title,
                scalar_definition("all_valid_text_field"),
                context: context,
            )
            text_or_keyword_result = validate_node(
                :status,
                scalar_definition("all_valid_text_or_keyword_field"),
                context: context,
            )
            non_text_result = validate_node(
                :status,
                scalar_definition("all_valid_non_text_field"),
                context: context,
            )

            expect(text_result).to eq(:title)
            expect(text_or_keyword_result).to eq(:status)
            expect(non_text_result).to eq(:status)

            expect do
                validate_node(
                    :title,
                    scalar_definition("all_valid_non_text_field"),
                    context: context,
                )
            end.to raise_error(ArgumentError)
        end

        it "sort_fieldは全targetの非textフィールドと特別値だけを許可する" do
            expect(
                validate_node(
                    :status,
                    scalar_definition("sort_field"),
                    context: context,
                ),
            ).to eq(:status)
            expect(
                validate_node(
                    :_score,
                    scalar_definition("sort_field"),
                    context: context,
                ),
            ).to eq(:_score)
            expect(
                validate_node(
                    :_doc,
                    scalar_definition("sort_field"),
                    context: context,
                ),
            ).to eq(:_doc)

            expect do
                validate_node(
                    :title,
                    scalar_definition("sort_field"),
                    context: context,
                )
            end.to raise_error(ArgumentError)
        end

        it "valid_modelはcontext内のClassだけを許可する" do
            result = validate_node(
                article_model,
                scalar_definition("valid_model"),
                context: context,
            )

            expect(result).to equal(article_model)

            expect do
                validate_node(
                    Class.new,
                    scalar_definition("valid_model"),
                    context: context,
                )
            end.to raise_error(ArgumentError)
        end

        it "Hash keyのtypeでも同じcontext集合を使用する" do
            definition = {
                hash: {
                    key_values: [
                        {
                            key: {
                                type: "all_valid_non_text_field",
                            },
                            value: scalar_definition("positive_integer"),
                        },
                    ],
                },
            }

            result = validate_node(
                {
                    status: 1,
                },
                definition,
                context: context,
            )

            expect(result).to eq(
                status: 1,
            )
        end

        it "フィールド名の表記に関係なくcontextに無いフィールドを拒否する" do
            values = [
                :_score,
                :"title.keyword",
                :fooBar,
                :"title*",
            ]

            values.each do |value|
                expect do
                    validate_node(
                        value,
                        scalar_definition("any_valid_field"),
                        context: context,
                    )
                end.to raise_error(ArgumentError)
            end
        end

        it "通常形式ではないフィールドもcontextにあれば許可する" do
            special_context = build_context(
                any_fields: [
                    :"title.keyword",
                    :fooBar,
                    :"title*",
                ],
            )

            special_context[:any_fields].each do |value|
                result = validate_node(
                    value,
                    scalar_definition("any_valid_field"),
                    context: special_context,
                )

                expect(result).to eq(value)
            end
        end

        it "contextは第3位置引数として必須" do
            expect do
                described_class.validate(
                    {},
                    {},
                )
            end.to raise_error(ArgumentError, /wrong number of arguments/)
        end

        it "context参照型は必要なcontextが無ければ拒否する" do
            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                )
            end.to raise_error(
                ArgumentError,
                "opts[:value] の検査には context[:any_fields] が必要です",
            )
        end

        it "contextのHash形式、必要キー、未知キーを検査する" do
            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: [],
                )
            end.to raise_error(
                ArgumentError,
                "context は Hash で指定してください: []",
            )

            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: {
                        models: [],
                    },
                )
            end.to raise_error(ArgumentError, /context に必要なキーがありません/)

            invalid_context = build_context(
                unknown: [],
            )

            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: invalid_context,
                )
            end.to raise_error(
                ArgumentError,
                "context に未知のキーがあります: [:unknown]",
            )
        end

        it "contextのmodelsをモデルClassのArrayに限定する" do
            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: build_context(
                        models: nil,
                    ),
                )
            end.to raise_error(
                ArgumentError,
                "context[:models] は Array で指定してください: nil",
            )

            invalid_model = Object.new

            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: build_context(
                        models: [invalid_model],
                    ),
                )
            end.to raise_error(
                ArgumentError,
                /context\[:models\] はモデルClassのArrayで指定してください/,
            )
        end

        it "contextのフィールド集合をStringまたはSymbolのArrayに限定する" do
            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: build_context(
                        any_fields: nil,
                    ),
                )
            end.to raise_error(
                ArgumentError,
                "context[:any_fields] は Array で指定してください: nil",
            )

            expect do
                validate_node(
                    :title,
                    scalar_definition("any_valid_field"),
                    context: build_context(
                        any_fields: [:title, 1],
                    ),
                )
            end.to raise_error(
                ArgumentError,
                "context[:any_fields] は String または Symbol のArrayで指定してください: 1",
            )
        end

        it "contextのフィールド名をSymbolへ統一し重複を除く" do
            string_context = build_context(
                any_fields: ["title", :title],
            )

            result = validate_node(
                :title,
                scalar_definition("any_valid_field"),
                context: string_context,
            )

            expect(result).to eq(:title)
        end
    end

    describe "OPTION_DEFINITIONSによるfields検査" do
        it "トップレベルfieldsのHash形式を維持する" do
            context = build_context(
                any_text_without_non_text_fields: [:title, :body],
            )

            result = described_class.validate(
                {
                    fields: {
                        title: 2.0,
                        body: 1,
                    },
                },
                AreSearch::Searcher::OPTION_DEFINITIONS,
                context,
            )

            expect(result[:fields]).to eq(
                title: 2.0,
                body: 1,
            )
        end

        it "トップレベルfieldsのArray形式を維持する" do
            context = build_context(
                any_text_without_non_text_fields: [:title, :body],
            )

            result = described_class.validate(
                {
                    fields: [:title, :body],
                },
                AreSearch::Searcher::OPTION_DEFINITIONS,
                context,
            )

            expect(result[:fields]).to eq([:title, :body])
        end

        it "トップレベルとqueries配下のfieldsの入力形式を維持する" do
            context = build_context(
                any_text_without_non_text_fields: [:title, :body],
            )

            result = described_class.validate(
                {
                    queries: [
                        {
                            query_string: "Rails",
                            fields: [:title, :body],
                        },
                        {
                            query_string: "Ruby",
                            fields: {
                                title: 2.0,
                            },
                        },
                    ],
                },
                AreSearch::Searcher::OPTION_DEFINITIONS,
                context,
            )

            expect(result[:queries][0][:fields]).to eq([:title, :body])
            expect(result[:queries][1][:fields]).to eq(
                title: 2.0,
            )
        end

        it "標準検索オプションのフィールド名はStringをSymbolへ変換せず拒否する" do
            context = build_context(
                any_text_without_non_text_fields: [:title],
                any_text_or_keyword_without_other_type_fields: [:title, :status],
                any_non_text_without_text_fields: [:status],
                all_valid_non_text_fields: [:status],
            )
            invalid_options = [
                [
                    {
                        fields: ["title"],
                    },
                    /context\[:any_text_without_non_text_fields\].*"title"/,
                ],
                [
                    {
                        fields: {
                            "title" => 2,
                        },
                    },
                    /opts\[:fields\] に未知のキーがあります: title/,
                ],
                [
                    {
                        queries: [
                            {
                                query_string: "Rails",
                                fields: ["title"],
                            },
                        ],
                    },
                    /context\[:any_text_without_non_text_fields\].*"title"/,
                ],
                [
                    {
                        mlt_params: {
                            fields: ["title"],
                        },
                    },
                    /context\[:any_text_or_keyword_without_other_type_fields\].*"title"/,
                ],
                [
                    {
                        where: {
                            "status" => {
                                term: "published",
                            },
                        },
                    },
                    /opts\[:where\] に未知のキーがあります: status/,
                ],
                [
                    {
                        sort: "status",
                    },
                    /context\[:all_valid_non_text_fields\].*"status"/,
                ],
                [
                    {
                        sort: {
                            "status" => :asc,
                        },
                    },
                    /opts\[:sort\] に未知のキーがあります: status/,
                ],
                [
                    {
                        aggs: {
                            "status" => {
                                size: 10,
                            },
                        },
                    },
                    /opts\[:aggs\] に未知のキーがあります: status/,
                ],
                [
                    {
                        highlight: {
                            fields: ["title"],
                        },
                    },
                    /context\[:any_text_or_keyword_without_other_type_fields\].*"title"/,
                ],
                [
                    {
                        highlight: {
                            fields: {
                                "title" => {
                                    number_of_fragments: 0,
                                },
                            },
                        },
                    },
                    /opts\[:highlight\]\[fields\] に未知のキーがあります: title/,
                ],
            ]

            invalid_options.each do |options, expected_message|
                expect do
                    described_class.validate(
                        options,
                        AreSearch::Searcher::OPTION_DEFINITIONS,
                        context,
                    )
                end.to raise_error(ArgumentError, expected_message)
            end
        end
    end
end
