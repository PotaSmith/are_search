# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchOptionDefinitionChecker do
    describe ".validate_option_definitions!" do
        describe "正常な定義" do
            it "Classと名前付きitem_typeを受け付ける" do
                definitions = {
                    query_string: [
                        {
                            item_type: String,
                        },
                    ],
                    page: [
                        {
                            item_type: "positive_integer",
                        },
                    ],
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end

            it "Array要素の候補定義を受け付ける" do
                definitions = {
                    fields: [
                        {
                            item_type: Array,
                            items: [
                                {
                                    item_type: "any_valid_text_field",
                                },
                            ],
                        },
                    ],
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end

            it "key_nameとmust_keysで固定キーを定義できる" do
                definitions = {
                    query: [
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
                                            item_type: "field_name",
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end

            it "同じkey_nameへ複数の値形式を定義できる" do
                definitions = {
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
                                                    item_type: "any_valid_text_field",
                                                },
                                            ],
                                        },
                                        {
                                            key_name: :fields,
                                            item_type: Hash,
                                            items: [
                                                {
                                                    key_type: "any_valid_text_field",
                                                    item_type: "positive_number",
                                                },
                                            ],
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end

            it "可変キーHashのkey_nameとkey_typeを受け付ける" do
                definitions = {
                    highlight: [
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
                                            item_type: "any_valid_text_or_keyword_field",
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
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end

            it "item_countとallow_emptyを受け付ける" do
                definitions = {
                    condition: [
                        {
                            item_type: Hash,
                            item_count: 1,
                            items: [
                                {
                                    key_type: "any_valid_non_text_field",
                                    item_type: Hash,
                                },
                            ],
                        },
                    ],
                    terms: [
                        {
                            item_type: Array,
                            allow_empty: true,
                            items: [
                                {
                                    item_type: "str_or_int_or_bool",
                                },
                            ],
                        },
                    ],
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end

            it "現行のcontext参照型を受け付ける" do
                definitions = {
                    fields: [
                        {
                            item_type: Array,
                            items: [
                                {
                                    item_type: "any_valid_text_field",
                                },
                                {
                                    item_type: "all_valid_text_search_field",
                                },
                            ],
                        },
                    ],
                    conditions: [
                        {
                            item_type: Hash,
                            items: [
                                {
                                    key_type: "any_valid_non_text_field",
                                    item_type: "str_or_int_or_bool",
                                },
                            ],
                        },
                    ],
                    models: [
                        {
                            item_type: Hash,
                            items: [
                                {
                                    key_type: "valid_model",
                                    item_type: "any",
                                },
                            ],
                        },
                    ],
                }

                result = described_class.validate_option_definitions!(definitions)

                expect(result).to eq(true)
            end
        end

        describe "トップレベル定義" do
            it "Hash以外と空Hashを拒否する" do
                expect do
                    described_class.validate_option_definitions!([])
                end.to raise_error(ArgumentError, /Hash/)

                expect do
                    described_class.validate_option_definitions!({})
                end.to raise_error(ArgumentError, /1件以上/)
            end

            it "Symbol以外のオプション名を拒否する" do
                definitions = {
                    "query_string" => [
                        {
                            item_type: String,
                        },
                    ],
                }

                expect do
                    described_class.validate_option_definitions!(definitions)
                end.to raise_error(ArgumentError, /オプション名は Symbol/)
            end

            it "候補定義がArrayではない場合と空Arrayを拒否する" do
                expect do
                    described_class.validate_option_definitions!(
                        query_string: {
                            item_type: String,
                        },
                    )
                end.to raise_error(ArgumentError, /Array/)

                expect do
                    described_class.validate_option_definitions!(
                        query_string: [],
                    )
                end.to raise_error(ArgumentError, /1件以上/)
            end
        end

        describe "定義ノード" do
            it "Hash以外、item_type欠落、未知キーを拒否する" do
                expect do
                    described_class.validate_option_definitions!(
                        query_string: [String],
                    )
                end.to raise_error(ArgumentError, /Hash/)

                expect do
                    described_class.validate_option_definitions!(
                        query_string: [{}],
                    )
                end.to raise_error(ArgumentError, /:item_type/)

                expect do
                    described_class.validate_option_definitions!(
                        query_string: [
                            {
                                item_type: String,
                                unknown: true,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /未知のキー/)
            end

            it "item_typeの型と名前を検査する" do
                expect do
                    described_class.validate_option_definitions!(
                        query_string: [
                            {
                                item_type: :string,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /Class または String/)

                expect do
                    described_class.validate_option_definitions!(
                        query_string: [
                            {
                                item_type: "unknown_type",
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /未知の独自型/)
            end

            it "Hash要素以外のkey_nameとkey_typeを拒否する" do
                expect do
                    described_class.validate_option_definitions!(
                        query_string: [
                            {
                                key_name: :query_string,
                                item_type: String,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /key_name/)

                expect do
                    described_class.validate_option_definitions!(
                        query_string: [
                            {
                                key_type: "symbol_key",
                                item_type: String,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /key_type/)
            end
        end

        describe "Hash要素のキー選択定義" do
            it "key_nameまたはkey_typeの片方だけを必要とする" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: [
                                    {
                                        item_type: String,
                                    },
                                ],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /どちらか一方/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: [
                                    {
                                        key_name: :title,
                                        key_type: "field_name",
                                        item_type: String,
                                    },
                                ],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /どちらか一方/)
            end

            it "key_nameとkey_typeの値を検査する" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: [
                                    {
                                        key_name: "title",
                                        item_type: String,
                                    },
                                ],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /key_name は Symbol/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: [
                                    {
                                        key_type: "unknown_type",
                                        item_type: String,
                                    },
                                ],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /未知の独自型/)
            end
        end

        describe "item_count、allow_empty、must_keys、must_not_keys" do
            it "使用できるitem_typeを限定する" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Array,
                                item_count: 1,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /item_count.*Hash/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                allow_empty: true,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /allow_empty.*Array/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Array,
                                must_keys: [:title],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /must_keys.*Hash/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Array,
                                must_not_keys: [:like],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /must_not_keys.*Hash/)
            end

            it "値の形式を検査する" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                item_count: -1,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /0以上/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Array,
                                allow_empty: false,
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /true/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                must_keys: [:title, :title],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /重複/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                must_not_keys: [],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /must_not_keys.*1件以上/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                must_not_keys: ["like"],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /must_not_keys.*Symbol/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                must_not_keys: [:like, :like],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /must_not_keys.*重複/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                must_keys: [:fields],
                                must_not_keys: [:fields],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /must_keys と :must_not_keys/)
            end

        end

        describe "items" do
            it "HashとArrayのitemsはArrayで指定する" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: {
                                    title: {
                                        item_type: String,
                                    },
                                },
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /:items は Array/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Array,
                                items: "field_name",
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /:items は Array/)
            end

            it "空の候補定義を拒否する" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: [],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /1件以上/)

                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Array,
                                items: [],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /1件以上/)
            end

            it "Hashのitems要素にはkey_nameまたはkey_typeを必要とする" do
                expect do
                    described_class.validate_option_definitions!(
                        values: [
                            {
                                item_type: Hash,
                                items: [
                                    {
                                        item_type: String,
                                    },
                                ],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /key_name または :key_type/)
            end
        end
    end
end
