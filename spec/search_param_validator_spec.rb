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

    let(:max_result_window) { 2_000 }

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
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                    count:  { type: "integer" },
                },
            )
        allow(index_target)
            .to receive(:are_search_index_mappings_for_index)
            .and_return(
                _source: {
                    includes: [:title],
                },
                properties: {
                    title:  { type: "text" },
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                    count:  { type: "integer" },
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


    # 成功した検証結果を返す。
    def validate_options(index_targets, models, **options)
        described_class.validate!(
            index_targets,
            models,
            max_result_window,
            **options,
        )
    end

    describe ".validate!" do
        it "定義されたnested HashとArrayを検査して入力形式を維持する" do
            result = described_class.validate!(
                [article_index_target],
                [article_model],
                max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
                    queries: [
                        {
                            query_string: "",
                            fields: [:status],
                        },
                    ],
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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
                    described_class.validate!(
                        [article_index_target],
                        [article_model],
                        max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
                    queries: [
                        {
                            query_string: "Rails",
                        },
                    ],
                )
            end.to raise_error(ArgumentError)
        end

        it "mltはfieldsとlikeの2要素を必須とし、likeはinstanceとindex_targetを必須にする" do
            result = validate_options(
                [article_index_target],
                [article_model],
                mlt: {
                    fields: [:title, :status],
                    like: {
                        instance:     mlt_instance,
                        index_target: mlt_index_target,
                    },
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
                fields: [:title, :status],
                like: {
                    instance:     mlt_instance,
                    index_target: mlt_index_target,
                },
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

            [:fields, :like].each do |required_key|
                mlt = {
                    fields: [:title],
                    like: {
                        instance:     mlt_instance,
                        index_target: mlt_index_target,
                    },
                }
                mlt.delete(required_key)

                expect do
                    described_class.validate!(
                        [article_index_target],
                        [article_model],
                        max_result_window,
                        mlt: mlt,
                    )
                end.to raise_error(ArgumentError)
            end

            [:instance, :index_target].each do |required_key|
                like = {
                    instance:     mlt_instance,
                    index_target: mlt_index_target,
                }
                like.delete(required_key)

                expect do
                    described_class.validate!(
                        [article_index_target],
                        [article_model],
                        max_result_window,
                        mlt: {
                            fields: [:title],
                            like:   like,
                        },
                    )
                end.to raise_error(ArgumentError)
            end

            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
                    mlt: {
                        fields: [:count],
                        like: {
                            instance:     mlt_instance,
                            index_target: mlt_index_target,
                        },
                    },
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
                    mlt: {
                        fields: [:title],
                        like: {
                            instance:     mlt_instance,
                            index_target: mlt_index_target,
                            fields:       [:title],
                        },
                    },
                )
            end.to raise_error(ArgumentError, /未知のキーがあります: :fields/)
        end

        it "mlt.fieldsは基準index targetの型と取得方法も検査する" do
            source_result = validate_options(
                [article_index_target],
                [article_model],
                mlt: {
                    fields: [:title],
                    like: {
                        instance:     mlt_instance,
                        index_target: mlt_index_target,
                    },
                },
            )
            store_result = validate_options(
                [article_index_target],
                [article_model],
                mlt: {
                    fields: [:status],
                    like: {
                        instance:     mlt_instance,
                        index_target: mlt_index_target,
                    },
                },
            )

            expect(source_result.dig(:mlt, :fields)).to eq([:title])
            expect(store_result.dig(:mlt, :fields)).to eq([:status])

            invalid_type_mappings = {
                _source: {
                    includes: [:title],
                },
                properties: {
                    title:  { type: "integer" },
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                    count:  { type: "integer" },
                },
            }

            allow(mlt_index_target)
                .to receive(:are_search_index_mappings_for_index)
                .and_return(invalid_type_mappings)

            expect do
                validate_options(
                    [article_index_target],
                    [article_model],
                    mlt: {
                        fields: [:title],
                        like: {
                            instance:     mlt_instance,
                            index_target: mlt_index_target,
                        },
                    },
                )
            end.to raise_error(ArgumentError, /text または keyword/)

            allow(mlt_index_target)
                .to receive(:are_search_index_mappings_for_index)
                .and_return(
                    _source: {
                        includes: [:title],
                    },
                    properties: {
                        title:  { type: "text" },
                        body:   { type: "text" },
                        status: { type: "keyword", store: true },
                        count:  { type: "integer" },
                    },
                )

            expect do
                validate_options(
                    [article_index_target],
                    [article_model],
                    mlt: {
                        fields: [:body],
                        like: {
                            instance:     mlt_instance,
                            index_target: mlt_index_target,
                        },
                    },
                )
            end.to raise_error(ArgumentError, /_source.*store/)
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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

        it "外部入力として使用する値が不正な場合はInvalidSearchOptionを送出する" do
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
                expect do
                    described_class.validate!(
                        [article_index_target],
                        [article_model],
                        max_result_window,
                        **options,
                    )
                end.to raise_error(AreSearch::InvalidSearchOption)
            end
        end

        it "外部入力以外の値が不正な場合は例外を伝播する" do
            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    per_page: -1,
                )
            end.to raise_error(ArgumentError, /0以上の整数/)
        end

    end
end

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

    let(:max_result_window) { 2_000 }

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
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                    count:  { type: "integer" },
                },
            )
        allow(index_target)
            .to receive(:are_search_index_mappings_for_index)
            .and_return(
                _source: {
                    includes: [:title],
                },
                properties: {
                    title:  { type: "text" },
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                    count:  { type: "integer" },
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


    # 成功した検証結果を返す。
    def validate_options(index_targets, models, **options)
        described_class.validate!(
            index_targets,
            models,
            max_result_window,
            **options,
        )
    end

    describe ".validate!" do
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
                described_class.validate!(
                    [article_index_target, document_index_target],
                    [article_model, document_model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target, document_index_target],
                    [article_model, document_model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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
                    described_class.validate!(
                        [article_index_target],
                        [article_model],
                        max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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
    end
end
