# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchParamValidator do
    let(:article_model) do
        Class.new do
            def self.name
                "Article"
            end
        end
    end

    let(:document_model) do
        Class.new do
            def self.name
                "Document"
            end
        end
    end

    let(:article_index_target) do
        double(
            "article_index_target",
            are_search_es_mappings: {
                properties: {
                    title:        { type: "text" },
                    body:         { type: "text" },
                    status:       { type: "keyword" },
                    count:        { type: "integer" },
                    published_at: { type: "date" },
                },
                runtime: {
                    runtime_title: { type: "text" },
                    runtime_score: { type: "double" },
                },
            },
        )
    end

    let(:document_index_target) do
        double(
            "document_index_target",
            are_search_es_mappings: {
                properties: {
                    title:  { type: "text" },
                    status: { type: "keyword" },
                    count:  { type: "integer" },
                },
            },
        )
    end

    describe ".validate" do
        it "定義されたnested HashとArrayのキーをSymbolへ統一する" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: ["title"],
                where: [
                    {
                        "status" => {
                            "term" => "published",
                        },
                    },
                ],
            )

            expect(result[:fields]).to eq([:title])
            expect(result[:where]).to eq([
                {
                    status: {
                        term: "published",
                    },
                },
            ])
        end

        it "fieldsはtext型のArrayまたは正のboostを持つHashを受け付ける" do
            array_result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: [:title, :runtime_title],
            )
            hash_result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: {
                    title: 2.0,
                    body:  1,
                },
            )

            expect(array_result[:fields]).to eq([:title, :runtime_title])
            expect(hash_result[:fields]).to eq([
                {
                    field: :title,
                    boost: 2.0,
                },
                {
                    field: :body,
                    boost: 1,
                },
            ])

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:status],
                )
            end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: {
                        title: 0,
                    },
                )
            end.to raise_error(ArgumentError, /正の数/)
        end

        it "未定義フィールドは表記に関係なく拒否する" do
            undefined_field_names = [
                :unknown_field,
                :"title.keyword",
                :fooBar,
                :"title*",
            ]

            undefined_field_names.each do |field_name|
                expect do
                    described_class.validate(
                        [article_index_target],
                        [article_model],
                        fields: [field_name],
                    )
                end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)
            end
        end

        it "queriesはquery_stringとfieldsを必須とし、fieldsのArrayとHashを受け付ける" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
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
            )

            expect(result[:queries][0]).to eq(
                query_string: "Rails",
                fields: [:title, :body],
            )
            expect(result[:queries][1]).to eq(
                query_string: "Ruby",
                fields: {
                    title: 2.0,
                },
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "Rails",
                        },
                    ],
                )
            end.to raise_error(ArgumentError, /必要なキー.*fields/)
        end

        it "mlt_paramsはfieldsを必須としfields以外の単体値パラメーターを受け付ける" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                mlt_params: {
                    fields:               [:title, :status],
                    min_term_freq:        1,
                    min_doc_freq:         2,
                    max_query_terms:      20,
                    min_word_length:      2,
                    minimum_should_match: "30%",
                    boost_terms:          1,
                },
            )

            expect(result[:mlt_params]).to eq(
                fields:               [:title, :status],
                min_term_freq:        1,
                min_doc_freq:         2,
                max_query_terms:      20,
                min_word_length:      2,
                minimum_should_match: "30%",
                boost_terms:          1,
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt_params: {
                        min_term_freq: 1,
                    },
                )
            end.to raise_error(ArgumentError, /必要なキー.*fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt_params: {
                        fields: [:runtime_score],
                    },
                )
            end.to raise_error(ArgumentError, /any_text_or_keyword_without_other_type_fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt_params: {
                        fields: {
                            title: 2.0,
                        },
                    },
                )
            end.to raise_error(ArgumentError, /Array/)

            future_param_result = described_class.validate(
                [article_index_target],
                [article_model],
                mlt_params: {
                    fields:       [:title],
                    future_param: true,
                },
            )

            expect(future_param_result[:mlt_params]).to eq(
                fields:       [:title],
                future_param: true,
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt_params: {
                        fields:       [:title],
                        future_param: 1.5,
                    },
                )
            end.to raise_error(
                ArgumentError,
                /String、Integer、true、falseのいずれか/,
            )
        end

        it "旧MLTトップレベルオプションを受け付けない" do
            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt_fields: [:title],
                )
            end.to raise_error(ArgumentError, /未知の検索オプション/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    min_term_freq: 1,
                )
            end.to raise_error(ArgumentError, /未知の検索オプション/)
        end

        it "where系は非textフィールドのterm、terms、rangeだけを受け付ける" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: [:title],
                where: {
                    status: {
                        term: "published",
                    },
                    count: {
                        terms: [1, 2],
                    },
                    published_at: {
                        range: {
                            gte: "2026-01-01",
                            lte: "2026-12-31",
                        },
                    },
                },
            )

            expect(result[:where]).to eq(
                status: {
                    term: "published",
                },
                count: {
                    terms: [1, 2],
                },
                published_at: {
                    range: {
                        gte: "2026-01-01",
                        lte: "2026-12-31",
                    },
                },
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    where: {
                        title: {
                            term: "Rails",
                        },
                    },
                )
            end.to raise_error(ArgumentError, /any_non_text_without_text_fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    where: {
                        status: "published",
                    },
                )
            end.to raise_error(ArgumentError)
        end

        it "where系の値をString、Integer、Booleanに限定する" do
            invalid_conditions = [
                {
                    status: {
                        term: [],
                    },
                },
                {
                    status: {
                        terms: ["published", {}],
                    },
                },
                {
                    count: {
                        range: {
                            gte: 1.5,
                        },
                    },
                },
            ]

            invalid_conditions.each do |where|
                expect do
                    described_class.validate(
                        [article_index_target],
                        [article_model],
                        fields: [:title],
                        where: where,
                    )
                end.to raise_error(ArgumentError)
            end
        end

        it "sortは全targetにある非textフィールドと_score、_docだけを受け付ける" do
            result = described_class.validate(
                [article_index_target, document_index_target],
                [article_model, document_model],
                fields: [:title],
                sort: {
                    status: :asc,
                    count:  :desc,
                    _score:  "desc",
                    _doc:    :asc,
                },
            )

            expect(result[:sort]).to eq(
                status: :asc,
                count:  :desc,
                _score:  "desc",
                _doc:    :asc,
            )

            expect do
                described_class.validate(
                    [article_index_target, document_index_target],
                    [article_model, document_model],
                    fields: [:title],
                    sort: [
                        {
                            status: :desc,
                        },
                    ],
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate(
                    [article_index_target, document_index_target],
                    [article_model, document_model],
                    fields: [:title],
                    sort: :published_at,
                )
            end.to raise_error(ArgumentError, /all_valid_non_text_fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    sort: :title,
                )
            end.to raise_error(ArgumentError, /all_valid_non_text_fields/)
        end

        it "aggsは非textフィールド、highlightはtextまたはkeywordフィールドを検査する" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: [:title],
                aggs: {
                    status: {
                        size: 20,
                    },
                    count: {
                        size: 10,
                    },
                },
                highlight: {
                    fields: {
                        title: {
                            fragment_size: 120,
                        },
                        status: {
                            number_of_fragments: 0,
                        },
                    },
                    type: "unified",
                    require_field_match: false,
                },
            )

            expect(result[:aggs]).to eq(
                status: {
                    size: 20,
                },
                count: {
                    size: 10,
                },
            )
            expect(result[:highlight]).to eq(
                fields: {
                    title: {
                        fragment_size: 120,
                    },
                    status: {
                        number_of_fragments: 0,
                    },
                },
                type: "unified",
                require_field_match: false,
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    aggs: {
                        title: {
                            size: 10,
                        },
                    },
                )
            end.to raise_error(ArgumentError, /any_non_text_without_text_fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    aggs: {
                        status: {
                            include: "published.*",
                        },
                    },
                )
            end.to raise_error(ArgumentError, /必要なキー.*size/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    aggs: {
                        status: {
                            size: 0,
                        },
                    },
                )
            end.to raise_error(ArgumentError, /正の整数で指定してください/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    aggs: [:status],
                )
            end.to raise_error(ArgumentError, /Hash/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    highlight: {
                        type: "unified",
                    },
                )
            end.to raise_error(ArgumentError, /必要なキー.*fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    highlight: {
                        fields: {
                            count: {
                                number_of_fragments: 0,
                            },
                        },
                    },
                )
            end.to raise_error(ArgumentError, /any_text_or_keyword_without_other_type_fields/)
        end

        it "pageとper_pageは正のIntegerだけを受け付ける" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: [:title],
                page: 2,
                per_page: 25,
            )

            expect(result[:page]).to eq(2)
            expect(result[:per_page]).to eq(25)

            [0, -1, 1.5, "1"].each do |value|
                expect do
                    described_class.validate(
                        [article_index_target],
                        [article_model],
                        fields: [:title],
                        page: value,
                    )
                end.to raise_error(ArgumentError, /正の整数/)
            end
        end

        it "model_includesとmodel_results_whereは対象モデルClassとnilではない値だけを許可する" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                fields: [:title],
                model_includes: {
                    article_model => [:user, :tags],
                },
                model_results_where: {
                    article_model => {
                        status: "published",
                    },
                },
            )

            expect(result[:model_includes]).to eq(
                article_model => [:user, :tags],
            )
            expect(result[:model_results_where]).to eq(
                article_model => {
                    status: "published",
                },
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    model_includes: {
                        document_model => [:author],
                    },
                )
            end.to raise_error(ArgumentError, /context\[:models\]/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    model_includes: {
                        article_model => nil,
                    },
                )
            end.to raise_error(ArgumentError, /nil は指定できません/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    fields: [:title],
                    model_results_where: {
                        article_model => nil,
                    },
                )
            end.to raise_error(ArgumentError, /nil は指定できません/)
        end

        it "raw_bodyとbuild_model_boolの型を検査する" do
            result = described_class.validate(
                [article_index_target],
                [article_model],
                raw_body: {
                    query: {
                        bool: {},
                    },
                },
                build_model_bool: true,
            )

            expect(result[:build_model_bool]).to eq(true)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    raw_body: [],
                )
            end.to raise_error(ArgumentError, /Hash/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    raw_body: {
                        query: {
                            bool: {},
                        },
                    },
                    build_model_bool: "true",
                )
            end.to raise_error(ArgumentError, /true または false/)
        end

        it "複数targetで同名フィールドの型が混在する場合はany_valid集合から除外する" do
            mixed_target = double(
                "mixed_target",
                are_search_es_mappings: {
                    properties: {
                        title:  { type: "keyword" },
                        status: { type: "text" },
                    },
                },
            )

            expect do
                described_class.validate(
                    [article_index_target, mixed_target],
                    [article_model, document_model],
                    fields: [:title],
                )
            end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)

            expect do
                described_class.validate(
                    [article_index_target, mixed_target],
                    [article_model, document_model],
                    where: {
                        status: {
                            term: "published",
                        },
                    },
                )
            end.to raise_error(ArgumentError, /any_non_text_without_text_fields/)
        end
    end
end

RSpec.describe AreSearch::SearcherUtils do
    describe ".build_model_filter_clause" do
        it "index targetのモデル名を重複させずterms条件を返す" do
            article_model = Class.new do
                def self.name
                    "Article"
                end
            end
            document_model = Class.new do
                def self.name
                    "Document"
                end
            end
            index_targets = [
                double("article_default", model_class: article_model),
                double("article_archive", model_class: article_model),
                double("document_default", model_class: document_model),
            ]

            result = described_class.build_model_filter_clause(index_targets)

            expect(result).to eq(
                terms: {
                    AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME => [
                        "Article",
                        "Document",
                    ],
                },
            )
        end
    end
end
