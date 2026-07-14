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

    describe ".validate のオプション定義Map処理" do
        it "オプション名をSymbolへ統一し、nilをそのまま残す" do
            definitions = {
                query_string: [
                    {
                        item_type: String,
                    },
                ],
            }

            result = described_class.validate(
                {
                    "query_string" => nil,
                },
                definitions,
            )

            expect(result).to eq(
                query_string: nil,
            )
        end

        it "未知のオプションと正規化後の重複を拒否する" do
            definitions = {
                page: [
                    {
                        item_type: Integer,
                    },
                ],
            }

            expect do
                described_class.validate(
                    {
                        unknown: 1,
                    },
                    definitions,
                )
            end.to raise_error(ArgumentError, /未知の検索オプション/)

            expect do
                described_class.validate(
                    {
                        "page" => 1,
                        page: 2,
                    },
                    definitions,
                )
            end.to raise_error(ArgumentError, /重複しています/)
        end
    end

    describe ".validate の候補定義処理" do
        it "先に一致した候補の正規化結果を返す" do
            definitions = [
                {
                    item_type: Integer,
                },
                {
                    item_type: "field_name",
                },
            ]

            result = described_class.validate("title", definitions)

            expect(result).to eq(:title)
        end

        it "候補が空、または全候補不一致なら拒否する" do
            expect do
                described_class.validate("title", [])
            end.to raise_error(ArgumentError, /1件以上の Array/)

            expect do
                described_class.validate(
                    :title,
                    [
                        {
                            item_type: Integer,
                        },
                        {
                            item_type: String,
                        },
                    ],
                )
            end.to raise_error(ArgumentError, /定義に一致しません/)
        end
    end

    describe ".validate の名前付きitem_type処理" do
        it "anyはHashとArrayを再帰的に複製する" do
            value = {
                "query" => [
                    {
                        "match_all" => {},
                    },
                ],
            }

            result = described_class.validate(
                value,
                {
                    item_type: "any",
                },
            )

            expect(result).to eq(value)
            expect(result).not_to equal(value)
            expect(result["query"]).not_to equal(value["query"])
            expect(result["query"][0]).not_to equal(value["query"][0])
        end

        it "anyはnilもそのまま許可する" do
            result = described_class.validate(
                nil,
                {
                    item_type: "any",
                },
            )

            expect(result).to eq(nil)
        end

        it "not_nilは型を限定せずnilだけを拒否する" do
            value = {
                "includes" => [:user, :tags],
            }

            result = described_class.validate(
                value,
                {
                    item_type: "not_nil",
                },
            )

            expect(result).to eq(value)
            expect(result).not_to equal(value)
            expect(result["includes"]).not_to equal(value["includes"])

            expect(
                described_class.validate(
                    false,
                    {
                        item_type: "not_nil",
                    },
                ),
            ).to eq(false)

            expect do
                described_class.validate(
                    nil,
                    {
                        item_type: "not_nil",
                    },
                )
            end.to raise_error(ArgumentError, /nil は指定できません/)
        end

        it "boolean、文字列系、数値系の独自型を検査する" do
            expect(
                described_class.validate(
                    false,
                    {
                        item_type: "boolean",
                    },
                ),
            ).to eq(false)

            expect(
                described_class.validate(
                    :desc,
                    {
                        item_type: "str_or_sym",
                    },
                ),
            ).to eq(:desc)

            expect(
                described_class.validate(
                    10,
                    {
                        item_type: "str_or_int",
                    },
                ),
            ).to eq(10)

            expect(
                described_class.validate(
                    true,
                    {
                        item_type: "str_or_int_or_bool",
                    },
                ),
            ).to eq(true)

            expect(
                described_class.validate(
                    2.5,
                    {
                        item_type: "positive_number",
                    },
                ),
            ).to eq(2.5)

            expect(
                described_class.validate(
                    2,
                    {
                        item_type: "positive_integer",
                    },
                ),
            ).to eq(2)
        end

        it "独自型が許可しない値を拒否する" do
            invalid_values = [
                ["boolean", 1],
                ["str_or_sym", 1],
                ["str_or_int", false],
                ["str_or_int_or_bool", 1.5],
                ["positive_number", 0],
                ["positive_integer", 1.5],
            ]

            invalid_values.each do |item_type, value|
                expect do
                    described_class.validate(
                        value,
                        {
                            item_type: item_type,
                        },
                    )
                end.to raise_error(ArgumentError)
            end
        end

        it "search_fieldをfieldとboostへ正規化する" do
            plain = described_class.validate(
                :title,
                {
                    item_type: "search_field",
                },
            )
            boosted = described_class.validate(
                "body^2.5",
                {
                    item_type: "search_field",
                },
            )

            expect(plain).to eq(
                field: :title,
                boost: nil,
            )
            expect(boosted).to eq(
                field: :body,
                boost: 2.5,
            )
        end

        it "field_nameはboostを持たないStringまたはSymbolだけを許可する" do
            expect(
                described_class.validate(
                    "title",
                    {
                        item_type: "field_name",
                    },
                ),
            ).to eq(:title)

            ["", "title^2", 1].each do |value|
                expect do
                    described_class.validate(
                        value,
                        {
                            item_type: "field_name",
                        },
                    )
                end.to raise_error(ArgumentError)
            end
        end
    end

    describe ".validate のArray処理" do
        it "各要素を候補定義で検査して正規化する" do
            definition = {
                item_type: Array,
                items: [
                    {
                        item_type: "field_name",
                    },
                ],
            }

            result = described_class.validate(
                ["title", :body],
                definition,
            )

            expect(result).to eq([:title, :body])
        end

        it "標準では空配列を拒否し、allow_empty指定時だけ許可する" do
            expect do
                described_class.validate(
                    [],
                    {
                        item_type: Array,
                        items: [
                            {
                                item_type: Integer,
                            },
                        ],
                    },
                )
            end.to raise_error(ArgumentError, /1件以上/)

            result = described_class.validate(
                [],
                {
                    item_type: Array,
                    allow_empty: true,
                    items: [
                        {
                            item_type: Integer,
                        },
                    ],
                },
            )

            expect(result).to eq([])
        end
    end

    describe ".validate のkey_name Hash処理" do
        it "必須の固定キーを検査し、StringキーをSymbolへ正規化する" do
            definition = {
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
                                item_type: "field_name",
                            },
                        ],
                    },
                ],
            }

            result = described_class.validate(
                {
                    "fields" => ["title"],
                    "query_string" => "Rails",
                },
                definition,
            )

            expect(result).to eq(
                fields: [:title],
                query_string: "Rails",
            )
        end

        it "同じkey_nameへ複数の値形式を定義できる" do
            definition = {
                item_type: Hash,
                must_keys: [:fields],
                items: [
                    {
                        key_name: :fields,
                        item_type: Array,
                        items: [
                            {
                                item_type: "field_name",
                            },
                        ],
                    },
                    {
                        key_name: :fields,
                        item_type: Hash,
                        items: [
                            {
                                key_type: "field_name",
                                item_type: "positive_number",
                            },
                        ],
                    },
                ],
            }

            array_result = described_class.validate(
                {
                    fields: [:title],
                },
                definition,
            )
            hash_result = described_class.validate(
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

        it "must_keysに指定したキーが無ければ拒否する" do
            definition = {
                item_type: Hash,
                must_keys: [:fields],
                items: [
                    {
                        key_name: :fields,
                        item_type: Array,
                    },
                ],
            }

            expect do
                described_class.validate(
                    {
                        unknown: true,
                    },
                    definition,
                )
            end.to raise_error(ArgumentError, /必要なキー/)
        end

        it "must_not_keysに指定したキーをStringキーも含めて拒否する" do
            definition = {
                item_type: Hash,
                must_not_keys: [:like],
                items: [
                    {
                        key_type: "symbol_key",
                        item_type: "str_or_int_or_bool",
                    },
                ],
            }

            [:like, "like"].each do |prohibited_key|
                expect do
                    described_class.validate(
                        {
                            prohibited_key => "other document",
                        },
                        definition,
                    )
                end.to raise_error(ArgumentError, /指定できないキー.*like/)
            end

            result = described_class.validate(
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
                item_type: Hash,
                must_keys: [:fields],
                items: [
                    {
                        key_name: :fields,
                        item_type: Array,
                        allow_empty: true,
                    },
                ],
            }

            expect do
                described_class.validate(
                    {
                        fields: [],
                        unknown: true,
                    },
                    definition,
                )
            end.to raise_error(ArgumentError, /定義に一致しません/)
        end

        it "Symbol化後に同じキーになる入力を拒否する" do
            definition = {
                item_type: Hash,
                must_keys: [:fields],
                items: [
                    {
                        key_name: :fields,
                        item_type: Array,
                        allow_empty: true,
                    },
                ],
            }

            expect do
                described_class.validate(
                    {
                        fields: [],
                        "fields" => [],
                    },
                    definition,
                )
            end.to raise_error(ArgumentError, /重複/)
        end
    end

    describe ".validate の可変キーHash処理" do
        it "key_nameを優先し、key_typeで残りのキーを検査する" do
            definition = {
                item_type: Hash,
                must_keys: [:fields],
                items: [
                    {
                        key_name: :fields,
                        item_type: Array,
                        items: [
                            {
                                item_type: "field_name",
                            },
                        ],
                    },
                    {
                        key_type: "symbol_key",
                        item_type: "str_or_int_or_bool",
                    },
                ],
            }

            result = described_class.validate(
                {
                    "fields" => ["title"],
                    "type" => "unified",
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
                item_type: Hash,
                item_count: 1,
                items: [
                    {
                        key_type: "symbol_key",
                        item_type: Integer,
                    },
                ],
            }

            expect do
                described_class.validate(
                    {
                        one: 1,
                        two: 2,
                    },
                    count_definition,
                )
            end.to raise_error(ArgumentError, /1 件/)

            required_definition = {
                item_type: Hash,
                must_keys: [:fields],
                items: [
                    {
                        key_type: "symbol_key",
                        item_type: Integer,
                    },
                ],
            }

            expect do
                described_class.validate(
                    {
                        size: 10,
                    },
                    required_definition,
                )
            end.to raise_error(ArgumentError, /必要なキー/)
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
            any_result = described_class.validate(
                :article_only,
                {
                    item_type: "any_valid_field",
                },
                context: context,
            )

            expect(any_result).to eq(:article_only)

            expect do
                described_class.validate(
                    :article_only,
                    {
                        item_type: "all_valid_field",
                    },
                    context: context,
                )
            end.to raise_error(ArgumentError, /all_fields/)
        end

        it "text、textまたはkeyword、非textの集合を区別する" do
            text_result = described_class.validate(
                :title,
                {
                    item_type: "all_valid_text_field",
                },
                context: context,
            )
            text_or_keyword_result = described_class.validate(
                :status,
                {
                    item_type: "all_valid_text_or_keyword_field",
                },
                context: context,
            )
            non_text_result = described_class.validate(
                :status,
                {
                    item_type: "all_valid_non_text_field",
                },
                context: context,
            )

            expect(text_result).to eq(:title)
            expect(text_or_keyword_result).to eq(:status)
            expect(non_text_result).to eq(:status)

            expect do
                described_class.validate(
                    :title,
                    {
                        item_type: "all_valid_non_text_field",
                    },
                    context: context,
                )
            end.to raise_error(ArgumentError, /all_valid_non_text_fields/)
        end

        it "search_fieldのboostを保持してcontextへ照合する" do
            result = described_class.validate(
                "title^2.5",
                {
                    item_type: "all_valid_text_search_field",
                },
                context: context,
            )

            expect(result).to eq(
                field: :title,
                boost: 2.5,
            )
        end

        it "sort_fieldは全targetの非textフィールドと特別値だけを許可する" do
            expect(
                described_class.validate(
                    :status,
                    {
                        item_type: "sort_field",
                    },
                    context: context,
                ),
            ).to eq(:status)
            expect(
                described_class.validate(
                    :_score,
                    {
                        item_type: "sort_field",
                    },
                    context: context,
                ),
            ).to eq(:_score)
            expect(
                described_class.validate(
                    :_doc,
                    {
                        item_type: "sort_field",
                    },
                    context: context,
                ),
            ).to eq(:_doc)

            expect do
                described_class.validate(
                    :title,
                    {
                        item_type: "sort_field",
                    },
                    context: context,
                )
            end.to raise_error(ArgumentError, /all_valid_non_text_fields/)
        end

        it "valid_modelはcontext内のClassだけを許可する" do
            result = described_class.validate(
                article_model,
                {
                    item_type: "valid_model",
                },
                context: context,
            )

            expect(result).to equal(article_model)

            expect do
                described_class.validate(
                    Class.new,
                    {
                        item_type: "valid_model",
                    },
                    context: context,
                )
            end.to raise_error(ArgumentError, /context\[:models\]/)
        end

        it "key_typeでも同じcontext集合を使用する" do
            definition = {
                item_type: Hash,
                items: [
                    {
                        key_type: "all_valid_non_text_field",
                        item_type: Integer,
                    },
                ],
            }

            result = described_class.validate(
                {
                    "status" => 1,
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
                    described_class.validate(
                        value,
                        {
                            item_type: "any_valid_field",
                        },
                        context: context,
                    )
                end.to raise_error(ArgumentError, /context\[:any_fields\]/)
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
                result = described_class.validate(
                    value,
                    {
                        item_type: "any_valid_field",
                    },
                    context: special_context,
                )

                expect(result).to eq(value)
            end
        end

        it "context未指定、欠落キー、未知キー、値型不正を拒否する" do
            expect do
                described_class.validate(
                    :title,
                    {
                        item_type: "any_valid_field",
                    },
                )
            end.to raise_error(ArgumentError, /context\[:any_fields\]/)

            expect do
                described_class.validate(
                    :title,
                    {
                        item_type: "any_valid_field",
                    },
                    context: {
                        models: [],
                    },
                )
            end.to raise_error(ArgumentError, /必要なキー/)

            invalid_context = build_context(
                unknown: [],
            )

            expect do
                described_class.validate(
                    :title,
                    {
                        item_type: "any_valid_field",
                    },
                    context: invalid_context,
                )
            end.to raise_error(ArgumentError, /未知のキー/)

            invalid_fields_context = build_context(
                any_fields: nil,
            )

            expect do
                described_class.validate(
                    :title,
                    {
                        item_type: "any_valid_field",
                    },
                    context: invalid_fields_context,
                )
            end.to raise_error(ArgumentError, /Array/)
        end

        it "contextのフィールド名をSymbolへ統一し重複を除く" do
            string_context = build_context(
                any_fields: ["title", :title],
            )

            result = described_class.validate(
                :title,
                {
                    item_type: "any_valid_field",
                },
                context: string_context,
            )

            expect(result).to eq(:title)
        end
    end

    describe "OPTION_DEFINITIONS固有の正規化" do
        it "トップレベルfieldsのHash形式をfieldとboostのArrayへ揃える" do
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
                context: context,
            )

            expect(result[:fields]).to eq([
                {
                    field: :title,
                    boost: 2.0,
                },
                {
                    field: :body,
                    boost: 1,
                },
            ])
        end

        it "queries配下のfieldsは定義に従ったArrayまたはHashの形を保つ" do
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
                context: context,
            )

            expect(result[:queries][0][:fields]).to eq([:title, :body])
            expect(result[:queries][1][:fields]).to eq(
                title: 2.0,
            )
        end
    end
end
