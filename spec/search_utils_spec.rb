# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchUtils do
    let(:helper_class) do
        Class.new do
            include AreSearch::SearchUtils
        end
    end
    let(:helper) { helper_class.new }
    let(:article_model) do
        double(
            "Article",
            name: "Article",
        )
    end
    let(:document_model) do
        double(
            "Document",
            name: "Document",
        )
    end
    let(:article_index_target) do
        double(
            "article_index_target",
            model_class: article_model,
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class: document_model,
        )
    end
    let(:valid_fields) do
        [
            :title,
            :status,
            :published_at,
            :category_id,
            :field1,
            :runtime_score,
        ]
    end

    describe "field typo check" do
        it "simple field name の未定義だけを typo 候補にする" do
            fields = [
                :title,
                :statuz,
                :published_at,
                :_score,
                :_field,
                :field_,
                :"title.keyword",
                :fooBar,
                :Title,
                :field1,
                :"title*",
            ]

            invalid = helper.invalid_typo_checkable_fields(fields, valid_fields)

            expect(invalid).to eq([:statuz])
        end

        it "properties と runtime のフィールドを収集する" do
            index_target = double(
                "index_target",
                are_search_es_mappings: {
                    properties: {
                        title: { type: "text" },
                    },
                    runtime: {
                        runtime_score: { type: "double" },
                    },
                },
            )

            fields = helper.collect_valid_fields([index_target])

            expect(fields).to eq([:title, :runtime_score])
        end
    end

    describe "fields" do
        it "combined_fields 用 fields は構造と typo だけを確認する" do
            expect do
                helper.validate_combined_fields_options!(
                    {
                        title: "ESへ渡すboost",
                        runtime_score: -1,
                    },
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.not_to raise_error
        end

        it "combined_fields 用 fields が未指定または対応外構造ならエラーにする" do
            expect do
                helper.validate_combined_fields_options!(
                    nil,
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:fields は必須です/)

            expect do
                helper.validate_combined_fields_options!(
                    :title,
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /Array または Hash/)
        end

        it "combined_fields 用 fields の typo を検出する" do
            expect do
                helper.validate_combined_fields_options!(
                    [:title, :statuz],
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:fields に未定義のフィールドがあります: \[:statuz\]/)
        end

        it "MLT 用 fields は Array と typo だけを確認する" do
            expect do
                helper.validate_mlt_fields_options!(
                    [:title, :runtime_score],
                    valid_fields,
                    caller_name: :more_like_this,
                )
            end.not_to raise_error

            expect do
                helper.validate_mlt_fields_options!(
                    { title: 2.0 },
                    valid_fields,
                    caller_name: :more_like_this,
                )
            end.to raise_error(ArgumentError, /:fields は Array/)
        end

        it "fields の Array と Hash を同じ内部形式へ変換する" do
            array_fields = helper.normalize_fields([:title, :status])
            hash_fields = helper.normalize_fields(title: 2.0, status: false)

            expect(array_fields).to eq([
                { name: :title, boost: nil },
                { name: :status, boost: nil },
            ])
            expect(hash_fields).to eq([
                { name: :title, boost: 2.0 },
                { name: :status, boost: false },
            ])
        end

        it "normalized_fields から combined_fields query を組み立てる" do
            clause = helper.build_combined_fields_clause(
                "Rails",
                [
                    { name: :title, boost: 2.0 },
                    { name: :status, boost: false },
                    { name: :published_at, boost: nil },
                ],
            )

            expect(clause).to eq(
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title^2.0", "status^false", "published_at"],
                    operator: "and",
                },
            )
        end
    end

    describe "sort" do
        it "フィールド名、Hash、Array の通常フィールドだけを typo 確認する" do
            expect do
                helper.validate_sort_options!(
                    [
                        "published_at",
                        { _score: :desc },
                        { :"title.keyword" => :asc },
                        { fooBar: :desc },
                    ],
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.not_to raise_error
        end

        it "sort の未定義通常フィールドを検出する" do
            expect do
                helper.validate_sort_options!(
                    { statuz: :desc },
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:sort に未定義のフィールドがあります: \[:statuz\]/)
        end

        it "AreSearch が読み取れない sort 構造をエラーにする" do
            expect do
                helper.validate_sort_options!(
                    [123],
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:sort の各要素/)
        end
    end

    describe "condition options" do
        it "where / where_not / where_or は Hash と Array<Hash> を受け付ける" do
            option_names = [:where, :where_not, :where_or]

            option_names.each do |option_name|
                expect do
                    helper.validate_condition_options!(
                        { status: "published" },
                        valid_fields,
                        option_name: option_name,
                        caller_name: :multi_search,
                    )
                end.not_to raise_error

                expect do
                    helper.validate_condition_options!(
                        [
                            {
                                field: :status,
                                value: Object.new,
                                boost: "ESへ渡す値",
                            },
                        ],
                        valid_fields,
                        option_name: option_name,
                        caller_name: :multi_search,
                    )
                end.not_to raise_error
            end
        end

        it "where / where_not / where_or の対応外構造をエラーにする" do
            expect do
                helper.validate_condition_options!(
                    :published,
                    valid_fields,
                    option_name: :where,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:where は Hash または Array<Hash>/)

            expect do
                helper.validate_condition_options!(
                    [123],
                    valid_fields,
                    option_name: :where_not,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:where_not の各要素は Hash/)
        end

        it "Array 条件の field または value が無ければ構造エラーにする" do
            expect do
                helper.validate_condition_options!(
                    [{ value: "published" }],
                    valid_fields,
                    option_name: :where_or,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:field が必要です/)

            expect do
                helper.validate_condition_options!(
                    [{ field: :status }],
                    valid_fields,
                    option_name: :where_or,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:value が必要です/)
        end

        it "Hash と Array 条件の typo 候補だけを未定義フィールドとして扱う" do
            expect do
                helper.validate_condition_options!(
                    { statuz: "published" },
                    valid_fields,
                    option_name: :where,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:where に未定義のフィールドがあります: \[:statuz\]/)

            expect do
                helper.validate_condition_options!(
                    [{ field: :statuz, value: "published" }],
                    valid_fields,
                    option_name: :where_or,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:where_or に未定義のフィールドがあります: \[:statuz\]/)

            conditions = {
                :_field => "x",
                :field_ => "x",
                :"title.keyword" => "x",
                :fooBar => "x",
            }

            expect do
                helper.validate_condition_options!(
                    conditions,
                    valid_fields,
                    option_name: :where_not,
                    caller_name: :multi_search,
                )
            end.not_to raise_error
        end

        it "Hash と Array<Hash> を同じ内部形式へ変換する" do
            hash_conditions = helper.normalize_condition_options(
                status: "published",
            )
            array_conditions = helper.normalize_condition_options(
                [
                    {
                        field: :status,
                        value: "published",
                        boost: 2.0,
                    },
                ],
            )

            expect(hash_conditions).to eq([
                {
                    field: :status,
                    value: "published",
                    boost: nil,
                },
            ])
            expect(array_conditions).to eq([
                {
                    field: :status,
                    value: "published",
                    boost: 2.0,
                },
            ])
        end

        it "共通内部形式から term / terms / range を組み立てる" do
            conditions = [
                {
                    field: :status,
                    value: "published",
                    boost: nil,
                },
                {
                    field: :category_id,
                    value: [1, 2],
                    boost: 2.0,
                },
                {
                    field: :published_at,
                    value: { gte: "2026-01-01" },
                    boost: 3.0,
                },
            ]

            clauses = helper.build_field_clauses(conditions)

            expect(clauses).to eq([
                { term: { status: "published" } },
                { terms: { category_id: [1, 2], boost: 2.0 } },
                { range: { published_at: { gte: "2026-01-01", boost: 3.0 } } },
            ])
        end
    end

    describe "bool" do
        it "モデルクラス名を filter に追加し、元の filter 配列は変更しない" do
            filter_clauses = [
                {
                    term: {
                        status: "published",
                    },
                },
            ]

            result = helper.build_bool_base(
                [article_index_target, document_index_target],
                filter_clauses,
                [],
                [],
            )

            expect(filter_clauses).to eq([
                {
                    term: {
                        status: "published",
                    },
                },
            ])
            expect(result[:filter]).to eq([
                {
                    term: {
                        status: "published",
                    },
                },
                {
                    terms: {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME =>
                            ["Article", "Document"],
                    },
                },
            ])
            expect(result).not_to have_key(:minimum_should_match)
        end

        it "where_or がある場合は minimum_should_match を1にする" do
            result = helper.build_bool_base(
                [article_index_target],
                [],
                [],
                [{ term: { status: "published" } }],
            )

            expect(result[:should]).to eq([
                { term: { status: "published" } },
            ])
            expect(result[:minimum_should_match]).to eq(1)
        end
    end

    describe "aggs" do
        it "構造と集計対象フィールドだけを確認する" do
            expect do
                helper.validate_aggs_options!(
                    [
                        :status,
                        {
                            category_id: {
                                size: -1,
                                order: { _count: :asc },
                            },
                        },
                    ],
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.not_to raise_error
        end

        it "個別設定が Hash でなければ構造エラーにする" do
            expect do
                helper.validate_aggs_options!(
                    [{ status: 10 }],
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:aggs の個別設定は Hash/)
        end

        it "デフォルトsizeを加えて内部形式へ変換する" do
            allow(AreSearch)
                .to receive(:default_aggs_size)
                .and_return(200)

            normalized = helper.normalize_aggs(
                [
                    :status,
                    {
                        category_id: {
                            size: -1,
                            order: { _count: :asc },
                        },
                    },
                ],
            )

            expect(normalized).to eq([
                {
                    field: :status,
                    terms_options: {
                        size: 200,
                    },
                },
                {
                    field: :category_id,
                    terms_options: {
                        size:  -1,
                        order: { _count: :asc },
                    },
                },
            ])
        end

        it "内部形式から terms aggregation を組み立てる" do
            body = helper.build_aggs(
                [
                    {
                        field: :status,
                        terms_options: {
                            size: 50,
                        },
                    },
                ],
            )

            expect(body).to eq(
                status: {
                    terms: {
                        size:  50,
                        field: :status,
                    },
                },
            )
        end
    end

    describe "highlight" do
        it "highlight が nil または fields 未指定なら検証を終える" do
            expect do
                helper.validate_highlight_options!(
                    nil,
                    valid_fields,
                    caller_name: :are_search_es_search,
                )
            end.not_to raise_error

            expect do
                helper.validate_highlight_options!(
                    { fragment_size: 150 },
                    valid_fields,
                    caller_name: :are_search_es_search,
                )
            end.not_to raise_error
        end

        it "Array省略形式、Hash形式、Array<Hash>形式のフィールドを確認する" do
            expect do
                helper.validate_highlight_options!(
                    {
                        fields: [
                            :title,
                            { body: { fragment_size: 150 } },
                        ],
                    },
                    valid_fields + [:body],
                    caller_name: :are_search_es_search,
                )
            end.not_to raise_error

            expect do
                helper.validate_highlight_options!(
                    {
                        fields: {
                            statuz: {},
                        },
                    },
                    valid_fields,
                    caller_name: :are_search_es_search,
                )
            end.to raise_error(ArgumentError, /:highlight に未定義のフィールドがあります: \[:statuz\]/)
        end

        it "fields が Hash または Array でなければ構造エラーにする" do
            expect do
                helper.validate_highlight_options!(
                    { fields: :title },
                    valid_fields,
                    caller_name: :are_search_es_search,
                )
            end.to raise_error(ArgumentError, /:fields は Hash または Array/)
        end

        it "Array省略形式を fields Hash へ変換する" do
            normalized = helper.normalize_highlight_options(
                {
                    fields: [
                        :title,
                        { body: { fragment_size: 150 } },
                    ],
                    number_of_fragments: 3,
                },
            )

            expect(normalized).to eq(
                fields: {
                    title: {},
                    body:  { fragment_size: 150 },
                },
                number_of_fragments: 3,
            )
        end

        it "fields が無ければ body 構築対象外へ変換する" do
            normalized = helper.normalize_highlight_options(
                fragment_size: 150,
            )

            expect(normalized).to eq(nil)
        end

        it "デフォルト値と highlight オプションをまとめて body にする" do
            body = helper.build_highlight_body(
                fields: {
                    body: {},
                },
                fragment_size:       200,
                number_of_fragments: 3,
                type:                "unified",
            )

            expect(body).to eq(
                pre_tags:            ["<em>"],
                post_tags:           ["</em>"],
                encoder:             "html",
                fields:              { body: {} },
                fragment_size:       200,
                number_of_fragments: 3,
                type:                "unified",
            )
        end

        it "利用側のタグとencoderを優先する" do
            body = helper.build_highlight_body(
                fields: {
                    body: {},
                },
                pre_tags:  ["<mark>"],
                post_tags: ["</mark>"],
                encoder:   "default",
            )

            expect(body).to eq(
                pre_tags:  ["<mark>"],
                post_tags: ["</mark>"],
                encoder:   "default",
                fields:    { body: {} },
            )
        end
    end
end
