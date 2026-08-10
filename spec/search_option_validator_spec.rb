# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchOptionValidator do
    def build_context(**overrides)
        context_values = {
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

        context = AreSearch::SearchOptionContext.new([], [], {})

        context_values.merge(overrides).each do |name, value|
            context.instance_variable_set("@#{name}", value)
        end

        context
    end

    # 単一nodeをトップレベルオプションとして検査し、nodeの結果だけを返す。
    def validate_node(value, definition, context: nil)
        result = described_class.validate!(
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

    describe ".validate! のArray処理" do
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

    describe ".validate! のkey_name Hash処理" do
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
                "opts[:value] に未知のキーがあります: :foo",
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
                "opts[:value] に未知のキーがあります: :unknown",
            )
        end

    end

    describe ".validate! の可変キーHash処理" do
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

end

RSpec.describe AreSearch::SearchOptionValidator do
    def build_context(**overrides)
        context_values = {
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

        context = AreSearch::SearchOptionContext.new([], [], {})

        context_values.merge(overrides).each do |name, value|
            context.instance_variable_set("@#{name}", value)
        end

        context
    end

    # 単一nodeをトップレベルオプションとして検査し、nodeの結果だけを返す。
    def validate_node(value, definition, context: nil)
        result = described_class.validate!(
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

    describe ".validate! のcontext参照型処理" do
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

            special_context.any_fields.each do |value|
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
                described_class.validate!(
                    {},
                    {},
                )
            end.to raise_error(ArgumentError, /wrong number of arguments/)
        end

    end

    describe "OPTION_DEFINITIONSによるfields検査" do
        it "トップレベルのquery_string・fields・query_typeを拒否する" do
            context = build_context(
                any_text_without_non_text_fields: [:title],
            )
            invalid_options = [
                { query_string: "Rails" },
                { fields: [:title] },
                { query_type: AreSearch::StandardQueryBuilder::TYPE_COMBINED_FIELDS },
            ]

            invalid_options.each do |options|
                expect do
                    described_class.validate!(
                        options,
                        AreSearch::SearchOptionValidator::OPTION_DEFINITIONS,
                        context,
                    )
                end.to raise_error(ArgumentError, /未知の検索オプション/)
            end
        end

        it "queries配下のfieldsのArray形式とHash形式を維持する" do
            context = build_context(
                any_text_without_non_text_fields: [:title, :body],
            )

            result = described_class.validate!(
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
                AreSearch::SearchOptionValidator::OPTION_DEFINITIONS,
                context,
            )

            expect(result[:queries][0][:fields]).to eq([:title, :body])
            expect(result[:queries][1][:fields]).to eq(
                title: 2.0,
            )
        end

        it "標準検索オプションのフィールド名はStringをSymbolへ変換せず拒否する" do
            mlt_model = Class.new do
                def self.include?(mod)
                    return true if mod == AreSearch::Searchable

                    super
                end
            end
            mlt_instance = mlt_model.new
            mlt_index_target = AreSearch::IndexTarget.allocate

            context = build_context(
                any_text_without_non_text_fields: [:title],
                any_text_or_keyword_without_other_type_fields: [:title, :status],
                any_non_text_without_text_fields: [:status],
                all_valid_non_text_fields: [:status],
            )
            invalid_options = [
                [
                    {
                        queries: [
                            {
                                query_string: "Rails",
                                fields: ["title"],
                            },
                        ],
                    },
                    /context\.any_text_without_non_text_fields.*"title"/,
                ],
                [
                    {
                        queries: [
                            {
                                query_string: "Rails",
                                fields: {
                                    "title" => 2,
                                },
                            },
                        ],
                    },
                    /opts\[:queries\]\[0\]\[fields\] に未知のキーがあります: "title"/,
                ],
                [
                    {
                        mlt: {
                            fields: ["title"],
                            like: {
                                instance:     mlt_instance,
                                index_target: mlt_index_target,
                            },
                        },
                    },
                    /context\.any_text_or_keyword_without_other_type_fields.*"title"/,
                ],
                [
                    {
                        where: {
                            "status" => {
                                term: "published",
                            },
                        },
                    },
                    /opts\[:where\] に未知のキーがあります: "status"/,
                ],
                [
                    {
                        sort: "status",
                    },
                    /context\.all_valid_non_text_fields.*"status"/,
                ],
                [
                    {
                        sort: {
                            "status" => :asc,
                        },
                    },
                    /opts\[:sort\] に未知のキーがあります: "status"/,
                ],
                [
                    {
                        aggs: {
                            "status" => {
                                terms: {
                                    field: :status,
                                },
                            },
                        },
                    },
                    /opts\[:aggs\] に未知のキーがあります: "status"/,
                ],
                [
                    {
                        highlight: {
                            fields: ["title"],
                        },
                    },
                    /context\.any_text_or_keyword_without_other_type_fields.*"title"/,
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
                    /opts\[:highlight\]\[fields\] に未知のキーがあります: "title"/,
                ],
            ]

            invalid_options.each do |options, expected_message|
                expect do
                    described_class.validate!(
                        options,
                        AreSearch::SearchOptionValidator::OPTION_DEFINITIONS,
                        context,
                    )
                end.to raise_error(ArgumentError, expected_message)
            end
        end
    end
end
