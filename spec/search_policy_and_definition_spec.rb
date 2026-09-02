# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchBodyPolicy do
    describe ".valid?" do
        it "継承クラスが実装しなければ例外にする" do
            policy_class = Class.new(described_class)

            expect do
                policy_class.valid?({})
            end.to raise_error(
                NotImplementedError,
                /valid\? を実装してください/,
            )
        end
    end

    describe ".invalid_key?" do
        it "継承クラスが実装しなければ例外にする" do
            policy_class = Class.new(described_class)

            expect do
                policy_class.invalid_key?(:script)
            end.to raise_error(
                NotImplementedError,
                /invalid_key\? を実装してください/,
            )
        end
    end
end

RSpec.describe AreSearch::ScriptDenySearchBodyPolicy do
    describe ".invalid_key?" do
        it "script に完全一致するキーを拒否する" do
            expect(described_class.invalid_key?(:script)).to eq(true)
        end

        it "script_ で始まるキーを拒否する" do
            expect(described_class.invalid_key?(:script_score)).to eq(true)
            expect(described_class.invalid_key?("script_fields")).to eq(true)
        end

        it "_script で終わるキーを拒否する" do
            expect(described_class.invalid_key?(:_script)).to eq(true)
            expect(described_class.invalid_key?("map_script")).to eq(true)
        end

        it "script を途中に含むだけのキーは拒否しない" do
            expect(described_class.invalid_key?(:description)).to eq(false)
            expect(described_class.invalid_key?(:transcript)).to eq(false)
            expect(described_class.invalid_key?(:subscription)).to eq(false)
        end
    end

    describe ".valid?" do
        it "Elasticsearch serializerでJSON化した後のキーを検査する" do
            serializer = double("serializer")
            es_params = Object.new

            allow(Elasticsearch::API)
                .to receive(:serializer)
                .and_return(serializer)

            expect(serializer)
                .to receive(:dump)
                .with(es_params)
                .and_return('{"query":{"script_score":{}}}')

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "serializerのJSON化に失敗した場合は例外を伝播する" do
            serializer = double("serializer")
            es_params = Object.new

            allow(Elasticsearch::API)
                .to receive(:serializer)
                .and_return(serializer)

            allow(serializer)
                .to receive(:dump)
                .with(es_params)
                .and_raise(ArgumentError, "cannot serialize")

            expect do
                described_class.valid?(es_params)
            end.to raise_error(ArgumentError, "cannot serialize")
        end

        it "script系のキーが無ければtrueを返す" do
            es_params = {
                query: {
                    bool: {
                        filter: [
                            { term: { status: "published" } },
                        ],
                    },
                },
                sort: [
                    { updated_at: :desc },
                ],
            }

            expect(described_class.valid?(es_params)).to eq(true)
        end

        it "scriptキーがあればfalseを返す" do
            es_params = {
                aggs: {
                    category_id: {
                        terms: {
                            script: {
                                source: "doc['category_id'].value",
                            },
                        },
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "_scriptキーがあればfalseを返す" do
            es_params = {
                sort: [
                    {
                        _script: {
                            type: :number,
                            order: :desc,
                        },
                    },
                ],
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "script_で始まるキーがあればfalseを返す" do
            es_params = {
                query: {
                    script_score: {
                        query: {
                            match_all: {},
                        },
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "_scriptで終わるStringキーもfalseを返す" do
            es_params = {
                "runtime_mappings" => {
                    "score" => {
                        "map_script" => {
                            "source" => "emit(1)",
                        },
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "scriptという通常フィールド名もfalseを返す" do
            es_params = {
                query: {
                    term: {
                        script: "latin",
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(false)
        end

        it "scriptを途中に含む通常フィールド名ならtrueを返す" do
            es_params = {
                query: {
                    bool: {
                        filter: [
                            { term: { description: "description" } },
                            { term: { transcript: "transcript" } },
                            { term: { subscription: "subscription" } },
                        ],
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(true)
        end

        it "値にscriptが含まれるだけならtrueを返す" do
            es_params = {
                query: {
                    term: {
                        category: "javascript",
                    },
                },
            }

            expect(described_class.valid?(es_params)).to eq(true)
        end
    end
end

RSpec.describe AreSearch::SearchParamPolicy do
    describe ".check_text" do
        it "基底policyは継承先でcheck_textを実装するよう要求する" do
            expect do
                described_class.check_text("query_string", "value")
            end.to raise_error(
                NotImplementedError,
                "AreSearch::SearchParamPolicy.check_text を実装してください",
            )
        end
    end

    describe ".check_field_value" do
        it "基底policyは継承先でcheck_field_valueを実装するよう要求する" do
            expect do
                described_class.check_field_value(:status, "where.term", "value")
            end.to raise_error(
                NotImplementedError,
                "AreSearch::SearchParamPolicy.check_field_value を実装してください",
            )
        end
    end

    describe ".validate!" do
        it "where内のfield名をSymbolのままcheck_field_valueへ渡す" do
            policy_class = Class.new(described_class)
            allow(policy_class).to receive(:check_field_value).and_return(nil)

            policy_class.validate!(
                where: {
                    filter: [
                        { status: { term: "published" } },
                    ],
                },
            )

            expect(policy_class).to have_received(:check_field_value).with(
                :status,
                "where.term",
                "published",
            )
        end

        it "whereのネストbool内も再帰してfield値を検査する" do
            policy_class = Class.new(described_class)
            allow(policy_class).to receive(:check_field_value).and_return(nil)

            policy_class.validate!(
                where: {
                    should: [
                        {
                            bool: {
                                filter: [
                                    { status: { term: "published" } },
                                ],
                            },
                        },
                    ],
                    minimum_should_match: 1,
                },
            )

            expect(policy_class).to have_received(:check_field_value).once.with(
                :status,
                "where.term",
                "published",
            )
        end
    end
end

RSpec.describe AreSearch::SearchParamLengthPolicy do
    describe ".check_text" do
        it "query_stringは2048文字までnilを返して2049文字でエラーメッセージを返す" do
            expect(described_class.check_text("query_string", "a" * 2048)).to eq(nil)
            expect(described_class.check_text("query_string", "a" * 2049)).to eq(
                "query_string は 2048 文字以内で指定してください",
            )
        end

        it "suggest.textは128文字までnilを返して129文字でエラーメッセージを返す" do
            expect(described_class.check_text("suggest.text", "a" * 128)).to eq(nil)
            expect(described_class.check_text("suggest.text", "a" * 129)).to eq(
                "suggest.text は 128 文字以内で指定してください",
            )
        end

        it "通常の文字・記号・空白を許可し制御文字や書式制御文字を拒否する" do
            valid_text = "abc 日本語 123 !?()[]{}+-*/=_~@#\u00a5\u20ac\u{1F642}"
            invalid_texts = [
                "abc\ndef",
                "abc\tdef",
                "abc\u200Bdef",
                "abc\uFEFFdef",
                "abc\u2028def",
            ]

            expect(described_class.check_text("query_string", valid_text)).to eq(nil)

            invalid_texts.each do |invalid_text|
                expect(described_class.check_text("query_string", invalid_text)).to eq(
                    "query_string は 不正な文字が含まれています。",
                )
            end
        end
    end

    describe ".check_field_value" do
        it "whereのArrayとHash内部にある不正文字を拒否する" do
            expect(described_class.check_field_value(:status, "where.term", "published\u200B")).to eq(
                "where.term は 不正な文字が含まれています。",
            )
            expect(described_class.check_field_value(:status, "where.terms", ["published", "draft\n"])).to eq(
                "where.terms は 不正な文字が含まれています。",
            )
            expect(described_class.check_field_value(:status, "where.range", { gte: "a", lte: "z\t" })).to eq(
                "where.range は 不正な文字が含まれています。",
            )
        end

        it "whereのterm値、terms全体、range全体の文字数境界を検査する" do
            expect(described_class.check_field_value(:status, "where.term", "a" * 128)).to eq(nil)
            expect(described_class.check_field_value(:status, "where.term", "a" * 129)).to eq(
                "where.term は 128 文字以内で指定してください",
            )

            terms_base_length = ["", "b"].to_s.length
            valid_terms = ["a" * (1024 - terms_base_length), "b"]
            invalid_terms = ["a" * (1025 - terms_base_length), "b"]

            expect(described_class.check_field_value(:status, "where.terms", valid_terms)).to eq(nil)
            expect(described_class.check_field_value(:status, "where.terms", invalid_terms)).to eq(
                "where.terms は 1024 文字以内で指定してください",
            )

            range_base_length = { gte: "", lte: "b" }.to_s.length
            valid_range = { gte: "a" * (256 - range_base_length), lte: "b" }
            invalid_range = { gte: "a" * (257 - range_base_length), lte: "b" }

            expect(described_class.check_field_value(:status, "where.range", valid_range)).to eq(nil)
            expect(described_class.check_field_value(:status, "where.range", invalid_range)).to eq(
                "where.range は 256 文字以内で指定してください",
            )
        end
    end

    describe ".valid_value?" do
        it "検索値として使用する型を許可する" do
            valid_values = [
                nil,
                "abc 日本語 !?",
                1,
                1.5,
                true,
                false,
                ["published", 1, 1.5, true, false, nil],
                { gte: 1, lte: 10, status: "published" },
            ]

            valid_values.each do |value|
                expect(described_class.valid_value?(value)).to eq(true)
            end
        end

        it "検索値として使用しない型を拒否する" do
            invalid_values = [
                :published,
                Object.new,
                Class.new,
                [:published],
                { status: Object.new },
            ]

            invalid_values.each do |value|
                expect(described_class.valid_value?(value)).to eq(false)
            end
        end

        it "ArrayとHashを再帰して不正文字と不正型を拒否する" do
            expect(described_class.valid_value?(["published", ["draft\n"]])).to eq(false)
            expect(described_class.valid_value?({ range: { gte: "a", lte: "z\t" } })).to eq(false)
            expect(described_class.valid_value?({ range: { gte: Object.new } })).to eq(false)
        end

        it "Hashのkeyは文字列化して不正文字を検査する" do
            expect(described_class.valid_value?({ status: "published" })).to eq(true)
            expect(described_class.valid_value?({ "status\n" => "published" })).to eq(false)
            expect(described_class.valid_value?({ :"status\t" => "published" })).to eq(false)
        end
    end

    describe ".validate!" do
        it "query_string、suggest.text、whereの不正文字を拒否する" do
            invalid_options = [
                {
                    queries: [
                        {
                            query_string: "abc\u200Bdef",
                        },
                    ],
                },
                {
                    suggest: {
                        title_spell: {
                            text: "abc\ndef",
                        },
                    },
                },
                {
                    where: {
                        filter: [
                            { status: { terms: ["published", "draft\t"] } },
                        ],
                    },
                },
            ]

            invalid_options.each do |options|
                expect do
                    described_class.validate!(**options)
                end.to raise_error(AreSearch::InvalidSearchOption, /不正な文字/)
            end
        end

        it "query_stringは2048文字まで許可して2049文字を拒否する" do
            expect do
                described_class.validate!(
                    queries: [
                        {
                            query_string: "a" * 2048,
                        },
                    ],
                )
            end.not_to raise_error

            expect do
                described_class.validate!(
                    queries: [
                        {
                            query_string: "a" * 2049,
                        },
                    ],
                )
            end.to raise_error(AreSearch::InvalidSearchOption)
        end

        it "suggestの名前配下のtextは128文字まで許可して129文字を拒否する" do
            expect do
                described_class.validate!(
                    suggest: {
                        title_spell: {
                            text: "a" * 128,
                        },
                    },
                )
            end.not_to raise_error

            expect do
                described_class.validate!(
                    suggest: {
                        title_spell: {
                            text: "a" * 129,
                        },
                    },
                )
            end.to raise_error(AreSearch::InvalidSearchOption)
        end

        it "where内のterm値、terms全体、range全体の文字数境界を検査する" do
            terms_base_length = ["", "b"].to_s.length
            range_base_length = { gte: "", lte: "b" }.to_s.length

            valid_conditions = [
                { status: { term: "a" * 128 } },
                { status: { terms: ["a" * (1024 - terms_base_length), "b"] } },
                { status: { range: { gte: "a" * (256 - range_base_length), lte: "b" } } },
            ]
            invalid_conditions = [
                { status: { term: "a" * 129 } },
                { status: { terms: ["a" * (1025 - terms_base_length), "b"] } },
                { status: { range: { gte: "a" * (257 - range_base_length), lte: "b" } } },
            ]

            valid_conditions.each do |condition|
                expect do
                    described_class.validate!(
                        where: {
                            filter: [condition],
                        },
                    )
                end.not_to raise_error
            end

            invalid_conditions.each do |condition|
                expect do
                    described_class.validate!(
                        where: {
                            filter: [condition],
                        },
                    )
                end.to raise_error(AreSearch::InvalidSearchOption)
            end
        end

        it "ネストbool内でもwhereの文字数制限を適用する" do
            expect do
                described_class.validate!(
                    where: {
                        should: [
                            {
                                bool: {
                                    filter: [
                                        { status: { term: "a" * 129 } },
                                    ],
                                },
                            },
                        ],
                        minimum_should_match: 1,
                    },
                )
            end.to raise_error(AreSearch::InvalidSearchOption)
        end

        it "nilのオプションがあっても後続の検索値を検査する" do
            expect do
                described_class.validate!(
                    queries: nil,
                    where: {
                        filter: [
                            { status: { term: "a" * 129 } },
                        ],
                    },
                )
            end.to raise_error(AreSearch::InvalidSearchOption)

            expect do
                described_class.validate!(
                    suggest: nil,
                    where: {
                        filter: [
                            { status: { term: "a" * 129 } },
                        ],
                    },
                )
            end.to raise_error(AreSearch::InvalidSearchOption)
        end
    end
end

RSpec.describe AreSearch::SearchOptionContext do
    describe ".build" do
        it "modelsをモデルClassのArrayに限定する" do
            expect do
                described_class.build([], nil, {})
            end.to raise_error(
                ArgumentError,
                "context.models は Array で指定してください: nil",
            )

            invalid_model = Object.new

            expect do
                described_class.build([], [invalid_model], {})
            end.to raise_error(
                ArgumentError,
                /context\.models はモデルClassのArrayで指定してください/,
            )
        end

        it "modelsの重複を除く" do
            model = Class.new

            context = described_class.build([], [model, model], {})

            expect(context.models).to eq([model])
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

    describe ".validate! のオプション定義Map処理" do
        it "Symbolのオプション名を扱い、nilは未指定として除外する" do
            definitions = {
                query_string: {
                    type: "any",
                },
            }

            result = described_class.validate!(
                {
                    query_string: nil,
                },
                definitions,
                nil,
            )

            expect(result).to eq({})
        end

        it "typeというオプション名も定義Mapとして扱う" do
            definitions = {
                type: scalar_definition("positive_integer"),
            }

            result = described_class.validate!(
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
                described_class.validate!(
                    {
                        unknown: 1,
                    },
                    definitions,
                    nil,
                )
            end.to raise_error(
                ArgumentError,
                "未知の検索オプションが指定されています: :unknown",
            )
        end

        it "Stringのオプション名をSymbolへ変換せず拒否する" do
            definitions = {
                page: scalar_definition("positive_integer"),
            }

            expect do
                described_class.validate!(
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

    describe ".validate! の候補定義処理" do
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

    describe ".validate! のerror_class処理" do
        it "オプション全体の検査エラーを指定例外へ付け替える" do
            definition = scalar_definition("positive_integer")
            definition[:error_class] = AreSearch::InvalidSearchOption

            expect do
                validate_node("1", definition)
            end.to raise_error(
                AreSearch::InvalidSearchOption,
                /正の整数/,
            )
        end

        it "Arrayのchildren以下の検査エラーだけを指定例外へ付け替える" do
            definition = {
                array: {
                    children: {
                        error_class: AreSearch::InvalidSearchOption,
                        scalar: {
                            type: "positive_integer",
                        },
                    },
                },
            }

            expect do
                validate_node([1, "2"], definition)
            end.to raise_error(
                AreSearch::InvalidSearchOption,
                /正の整数/,
            )

            expect do
                validate_node("2", definition)
            end.to raise_error(ArgumentError, /node_type :scalar/)
        end

        it "Hashのvalue以下の検査エラーだけを指定例外へ付け替える" do
            definition = {
                hash: {
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
                    ],
                },
            }

            expect do
                validate_node(
                    {
                        query_string: nil,
                    },
                    definition,
                )
            end.to raise_error(
                AreSearch::InvalidSearchOption,
                /String/,
            )

            expect do
                validate_node(
                    {
                        fields: [:title],
                    },
                    definition,
                )
            end.to raise_error(ArgumentError, /未知のキー/)
        end
    end

    describe ".validate! の名前付きtype処理" do
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

        it "anyはネストしたnilもそのまま許可する" do
            result = validate_node(
                {
                    value: nil,
                },
                {
                    hash: {
                        key_values: [
                            {
                                key: {
                                    key_name: :value,
                                },
                                value: {
                                    type: "any",
                                },
                            },
                        ],
                    },
                },
            )

            expect(result).to eq(
                value: nil,
            )
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
                validate_node(
                    {
                        value: nil,
                    },
                    {
                        hash: {
                            key_values: [
                                {
                                    key: {
                                        key_name: :value,
                                    },
                                    value: definition,
                                },
                            ],
                        },
                    },
                )
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
                    1.5,
                    scalar_definition("str_or_int_or_float_or_bool"),
                ),
            ).to eq(1.5)

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
                ["str_or_int_or_float_or_bool", :invalid, /String、Integer、Float、true、false/],
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

            [
                "title",
                :_title,
                :title_,
                :"title.keyword",
                :are_search_reserved_ar_instance_key,
                1,
            ].each do |value|
                expect do
                    validate_node(
                        value,
                        scalar_definition("symbol_key"),
                    )
                end.to raise_error(ArgumentError)
            end
        end
    end
end
