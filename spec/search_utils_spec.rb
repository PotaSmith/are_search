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
            are_search_index_mappings: {
                properties: {
                    title:        { type: "text" },
                    body:         { type: "text" },
                    status:       { type: "keyword" },
                    count:        { type: "integer" },
                    score:        { type: "double" },
                    published_at: { type: "date" },
                },
            },
        )
    end


    let(:mlt_index_target) do
        index_target = AreSearch::IndexTarget.allocate

        allow(index_target)
            .to receive(:index_target_name)
            .and_return(:default)
        allow(index_target)
            .to receive(:are_search_index_alias_name)
            .and_return("test__articles__default")
        allow(index_target)
            .to receive(:are_search_index_mappings)
            .and_return(
                properties: {
                    title:  { type: "text" },
                    status: { type: "keyword" },
                },
            )

        index_target
    end

    let(:mlt_instance) do
        model = Class.new do
            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end
        end

        allow(model)
            .to receive(:are_search_index_target)
            .with(:default)
            .and_return(mlt_index_target)

        model.new
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            are_search_index_mappings: {
                properties: {
                    title:  { type: "text" },
                    status: { type: "keyword" },
                    count:  { type: "integer" },
                },
            },
        )
    end


    # 成功した検証結果だけを取り出し、エラーが返っていないことを確認する。
    def validate_options(index_targets, models, **options)
        valid_options, error_message = described_class.validate(
            index_targets,
            models,
            **options,
        )

        expect(error_message).to eq(nil)

        valid_options
    end

    describe ".validate" do
        it "定義されたnested HashとArrayを検査して入力形式を維持する" do
            result, error_message = described_class.validate(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                where: [
                    {
                        status: {
                            term: "published",
                        },
                    },
                ],
            )

            expect(error_message).to eq(nil)
            expect(result.dig(:queries, 0, :fields)).to eq([:title])
            expect(result[:where]).to eq([
                {
                    status: {
                        term: "published",
                    },
                },
            ])
        end

        it "queries配下のfieldsはtext型のArrayまたは正のboostを持つHashを受け付ける" do
            array_result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title, :body],
                    },
                ],
            )
            hash_result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: {
                            title: 2.0,
                            body:  1,
                        },
                    },
                ],
            )

            expect(array_result.dig(:queries, 0, :fields)).to eq([:title, :body])
            expect(hash_result.dig(:queries, 0, :fields)).to eq(
                title: 2.0,
                body: 1,
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:status],
                        },
                    ],
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: {
                                title: 0,
                            },
                        },
                    ],
                )
            end.to raise_error(ArgumentError)
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
                        queries: [
                            {
                                query_string: "",
                                fields: [field_name],
                            },
                        ],
                    )
                end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)
            end
        end

        it "queriesはquery_stringとfieldsを必須とし、fieldsのArrayとHashを受け付ける" do
            result = validate_options(
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
            end.to raise_error(ArgumentError)
        end

        it "mltはinstance、index_target、fieldsを必須とし、その他のパラメーターを値の型を限定せず受け付ける" do
            result = validate_options(
                [article_index_target],
                [article_model],
                mlt: {
                    instance:             mlt_instance,
                    index_target:         mlt_index_target,
                    fields:               [:title, :status],
                    min_term_freq:        1,
                    min_doc_freq:         2,
                    max_query_terms:      20,
                    min_word_length:      2,
                    minimum_should_match: "30%",
                    boost_terms:          1.5,
                    stop_words:           ["ruby", "rails"],
                    per_field_analyzer: {
                        title:  "standard",
                        status: "keyword",
                    },
                },
            )

            expect(result[:mlt]).to eq(
                instance:             mlt_instance,
                index_target:         mlt_index_target,
                fields:               [:title, :status],
                min_term_freq:        1,
                min_doc_freq:         2,
                max_query_terms:      20,
                min_word_length:      2,
                minimum_should_match: "30%",
                boost_terms:          1.5,
                stop_words:           ["ruby", "rails"],
                per_field_analyzer: {
                    title:  "standard",
                    status: "keyword",
                },
            )

            required_keys = [
                :instance,
                :index_target,
                :fields,
            ]

            required_keys.each do |required_key|
                mlt = {
                    instance:     mlt_instance,
                    index_target: mlt_index_target,
                    fields:       [:title],
                }
                mlt.delete(required_key)

                expect do
                    described_class.validate(
                        [article_index_target],
                        [article_model],
                        mlt: mlt,
                    )
                end.to raise_error(ArgumentError)
            end

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt: {
                        instance:     mlt_instance,
                        index_target: mlt_index_target,
                        fields:       [:count],
                    },
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    mlt: {
                        instance:     mlt_instance,
                        index_target: mlt_index_target,
                        fields: {
                            title: 2.0,
                        },
                    },
                )
            end.to raise_error(ArgumentError)
        end

        it "where系は非textフィールドのterm、terms、rangeだけを受け付ける" do
            result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
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
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    where: {
                        title: {
                            term: "Rails",
                        },
                    },
                )
            end.to raise_error(
                ArgumentError,
                /opts\[:where\] に未知のキーがあります: :title/,
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    where: {
                        status: "published",
                    },
                )
            end.to raise_error(ArgumentError)
        end

        it "where系のterm、terms、rangeはFloatを受け付ける" do
            result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                where: [
                    {
                        score: {
                            term: 1.5,
                        },
                    },
                    {
                        score: {
                            terms: [1.5, 2.5],
                        },
                    },
                    {
                        score: {
                            range: {
                                gte: 1.5,
                                lte: 2.5,
                            },
                        },
                    },
                ],
            )

            expect(result[:where]).to eq([
                {
                    score: {
                        term: 1.5,
                    },
                },
                {
                    score: {
                        terms: [1.5, 2.5],
                    },
                },
                {
                    score: {
                        range: {
                            gte: 1.5,
                            lte: 2.5,
                        },
                    },
                },
            ])
        end

        it "外部入力として使用する値が不正な場合はエラーメッセージを返す" do
            invalid_options = [
                {
                    queries: [
                        {
                            query_string: nil,
                            fields: [:title],
                        },
                    ],
                },
                {
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    where: {
                        status: {
                            term: [],
                        },
                    },
                },
                {
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    where: {
                        status: {
                            terms: ["published", {}],
                        },
                    },
                },
                {
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    where: {
                        count: {
                            range: {
                                gte: 1..2,
                            },
                        },
                    },
                },
                {
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    page: "2",
                },
            ]

            invalid_options.each do |options|
                valid_options, error_message = described_class.validate(
                    [article_index_target],
                    [article_model],
                    **options,
                )

                expect(valid_options).to eq(nil)
                expect(error_message).to be_instance_of(String)
                expect(error_message.empty?).to eq(false)
            end
        end

        it "外部入力以外の値が不正な場合は例外を伝播する" do
            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    per_page: 0,
                )
            end.to raise_error(ArgumentError, /正の整数/)
        end

        it "sortは全targetにある非textフィールドと_score、_docだけを受け付ける" do
            result = validate_options(
                [article_index_target, document_index_target],
                [article_model, document_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
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
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
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
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    sort: :published_at,
                )
            end.to raise_error(ArgumentError, /all_valid_non_text_fields/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    sort: :title,
                )
            end.to raise_error(ArgumentError, /all_valid_non_text_fields/)
        end

        it "aggsはArray簡易形式とfieldを持つElasticsearch形式を受け付ける" do
            array_result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                aggs: [:status, :count],
            )
            hash_result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                aggs: {
                    status_count: {
                        terms: {
                            field: :status,
                            size: 20,
                            include: {
                                partition: 0,
                                num_partitions: 20,
                            },
                        },
                    },
                    score_ranges: {
                        range: {
                            field: :score,
                            ranges: [
                                { to: 1.0 },
                                { from: 1.0, to: 2.0, key: "middle" },
                                { from: 2.0 },
                            ],
                            keyed: true,
                        },
                    },
                    average_score: {
                        avg: {
                            field: :score,
                            missing: 0,
                        },
                    },
                },
            )

            expect(array_result[:aggs]).to eq([:status, :count])
            expect(hash_result[:aggs]).to eq(
                status_count: {
                    terms: {
                        field: :status,
                        size: 20,
                        include: {
                            partition: 0,
                            num_partitions: 20,
                        },
                    },
                },
                score_ranges: {
                    range: {
                        field: :score,
                        ranges: [
                            { to: 1.0 },
                            { from: 1.0, to: 2.0, key: "middle" },
                            { from: 2.0 },
                        ],
                        keyed: true,
                    },
                },
                average_score: {
                    avg: {
                        field: :score,
                        missing: 0,
                    },
                },
            )
        end

        it "aggsは集計名と対象フィールドだけを検査する" do
            invalid_aggs = [
                [:title],
                {
                    title_count: {
                        terms: {
                            field: :title,
                        },
                    },
                },
                {
                    title_average: {
                        avg: {
                            field: :title,
                        },
                    },
                },
                {
                    missing_field: {
                        avg: {
                            missing: 0,
                        },
                    },
                },
                {
                    status_count: {
                        terms: {
                            field: :status,
                        },
                        range: {
                            field: :score,
                        },
                    },
                },
                {
                    status: {
                        size: 20,
                    },
                },
            ]

            invalid_aggs.each do |aggs|
                expect do
                    described_class.validate(
                        [article_index_target],
                        [article_model],
                        queries: [
                            {
                                query_string: "",
                                fields: [:title],
                            },
                        ],
                        aggs: aggs,
                    )
                end.to raise_error(ArgumentError)
            end
        end

        it "highlightはfieldsだけを検査してその他の指定を維持する" do
            result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                highlight: {
                    fields: {
                        title: {},
                        status: {
                            matched_fields: [:title, :status],
                        },
                    },
                    pre_tags: ["<mark>"],
                    post_tags: ["</mark>"],
                    options: {
                        custom: [1, true, nil],
                    },
                },
            )

            expect(result[:highlight]).to eq(
                fields: {
                    title: {},
                    status: {
                        matched_fields: [:title, :status],
                    },
                },
                pre_tags: ["<mark>"],
                post_tags: ["</mark>"],
                options: {
                    custom: [1, true, nil],
                },
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    highlight: {
                        type: "unified",
                    },
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    highlight: {
                        fields: {
                            count: {},
                        },
                    },
                )
            end.to raise_error(ArgumentError)
        end

        it "pageとper_pageは正のIntegerだけを受け付ける" do
            result = validate_options(
                [article_index_target],
                [article_model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                page: 2,
                per_page: 25,
            )

            expect(result[:page]).to eq(2)
            expect(result[:per_page]).to eq(25)
        end

        it "不正なpageはエラーメッセージを返し不正なper_pageは例外にする" do
            [0, -1, 1.5, "1"].each do |value|
                valid_options, error_message = described_class.validate(
                    [article_index_target],
                    [article_model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    page: value,
                )

                expect(valid_options).to eq(nil)
                expect(error_message).to match(/正の整数/)
            end

            [0, -1, 1.5, "1"].each do |value|
                expect do
                    described_class.validate(
                        [article_index_target],
                        [article_model],
                        queries: [
                            {
                                query_string: "",
                                fields: [:title],
                            },
                        ],
                        per_page: value,
                    )
                end.to raise_error(ArgumentError, /正の整数/)
            end
        end

        it "model_relationsは対象モデルと同じklassのActiveRecord::Relationだけを許可する" do
            model = AreSearch::SyncRequest
            relation = model.where(last_error: nil)

            result = validate_options(
                [article_index_target],
                [model],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                model_relations: {
                    model => relation,
                },
            )

            expect(result[:model_relations][model]).to equal(relation)

            expect do
                described_class.validate(
                    [article_index_target],
                    [model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    model_relations: {
                        document_model => relation,
                    },
                )
            end.to raise_error(
                ArgumentError,
                /opts\[:model_relations\] に未知のキーがあります/,
            )

            expect do
                described_class.validate(
                    [article_index_target],
                    [model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    model_relations: {
                        model => nil,
                    },
                )
            end.to raise_error(ArgumentError, /ActiveRecord::Relation/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    model_relations: {
                        model => Object.new,
                    },
                )
            end.to raise_error(ArgumentError, /ActiveRecord::Relation/)

            expect do
                described_class.validate(
                    [article_index_target],
                    [model],
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    model_relations: {
                        model => AreSearch::IndexMarker.all,
                    },
                )
            end.to raise_error(
                ArgumentError,
                /モデルと Relation の klass が一致していません/,
            )
        end

        it "raw_bodyとbuild_model_boolの型を検査する" do
            result = validate_options(
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
            end.to raise_error(ArgumentError)

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
            end.to raise_error(ArgumentError)
        end

        it "複数targetで同名フィールドの型が混在する場合はany_valid集合から除外する" do
            mixed_target = double(
                "mixed_target",
                are_search_index_mappings: {
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
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
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
            end.to raise_error(
                ArgumentError,
                /opts\[:where\] に未知のキーがあります: :status/,
            )
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
                    AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME => [
                        "Article",
                        "Document",
                    ],
                },
            )
        end
    end
end
