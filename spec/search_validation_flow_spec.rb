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

        it "pageとper_pageから算出した開始位置がmax_result_window以上なら拒否する" do
            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    30,
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    page: 3,
                    per_page: 20,
                )
            end.to raise_error(AreSearch::InvalidSearchOption, /max_result_window/)

            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    30,
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    page: 2,
                    per_page: 20,
                )
            end.not_to raise_error
        end

        it "不正なpageはInvalidSearchOptionを送出し不正なper_pageはArgumentErrorにする" do
            [0, -1, 1.5, "1"].each do |value|
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
                        page: value,
                    )
                end.to raise_error(AreSearch::InvalidSearchOption, /正の整数/)
            end

            [0, -1, 1.5, "1"].each do |value|
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
                described_class.validate!(
                    [article_index_target],
                    [model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target],
                    [model],
                    max_result_window,
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                    model_relations: {
                        model => AreSearch::SyncLock.all,
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
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
                    raw_body: [],
                )
            end.to raise_error(ArgumentError)

            expect do
                described_class.validate!(
                    [article_index_target],
                    [article_model],
                    max_result_window,
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
                described_class.validate!(
                    [article_index_target, mixed_target],
                    [article_model, document_model],
                    max_result_window,
                    queries: [
                        {
                            query_string: "",
                            fields: [:title],
                        },
                    ],
                )
            end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)

            expect do
                described_class.validate!(
                    [article_index_target, mixed_target],
                    [article_model, document_model],
                    max_result_window,
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

RSpec.describe "search option flow" do
    let(:article_model) do
        Class.new do
            attr_reader :id

            def self.name
                "Article"
            end

            def self.are_search_ar_table_name
                "articles"
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            # 実際のSearchableモデルと同じ入口からIndexTargetを解決する。
            def self.are_search_index_target(index_target_name)
                AreSearch::IndexTarget.new(self, index_target_name)
            end

            def self.default_properties
                {
                    title:  { type: "text" },
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                    count:  { type: "integer" },
                }
            end

            def self.mlt_source_properties
                {
                    title:  { type: "integer" },
                    body:   { type: "text" },
                    status: { type: "keyword", store: true },
                }
            end

            def initialize
                @id = 1
            end
        end
    end

    let(:article) do
        article_model.new
    end

    let(:article_index_target) do
        AreSearch::IndexTarget.new(article_model, :default)
    end

    let(:mlt_source_index_target) do
        AreSearch::IndexTarget.new(article_model, :mlt_source)
    end

    around do |example|
        original_searchable_class_setting = AreSearch.searchable_class_setting
        AreSearch.searchable_class_setting = {
            "Article" => {
                default: {
                    settings: {
                        max_result_window: 2_000,
                    },
                    mappings: {
                        _source: {
                            includes: [:title],
                        },
                    },
                    properties_method: :default_properties,
                },
                mlt_source: {
                    settings: {
                        max_result_window: 2_000,
                    },
                    mappings: {},
                    properties_method: :mlt_source_properties,
                },
            },
        }

        example.run
    ensure
        AreSearch.searchable_class_setting = original_searchable_class_setting
    end

    before do
        allow(AreSearch)
            .to receive(:index_prefix)
            .and_return("test")

        allow(AreSearch::EsAdapter)
            .to receive(:index_alias_exists?)
            .with(index_alias_name: "test__articles__default")
            .and_return(true)

        allow(AreSearch::EsAdapter)
            .to receive(:index_alias_exists?)
            .with(index_alias_name: "test__articles__mlt_source")
            .and_return(true)
    end

    it "queries配下のquery_stringにStringを受け付ける" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            dump_body: true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :combined_fields, :query),
        ).to eq("Rails")
    end

    it "queries配下の未定義query_typeを拒否する" do
        invalid_query_types = [
            :query_string,
            "simple_query_string",
            1,
        ]

        invalid_query_types.each do |query_type|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "Rails",
                            fields:       [:title],
                            query_type:   query_type,
                        },
                    ],
                )
            end.to raise_error(ArgumentError, /query_type/)
        end
    end

    it "空文字列ではcombined_fields句を作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
            ],
            dump_body:    true,
        )

        expect(body.dig(:query, :bool)).not_to have_key(:must)
    end

    it "query_stringが制約に合わない場合はparams_invalidの空結果を返す" do
        invalid_query_strings = [
            nil,
            1,
            :query,
            true,
            false,
            {},
            [],
        ]

        invalid_query_strings.each do |query_string|
            result = AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: query_string,
                        fields:       [:title],
                    },
                ],
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
            expect(result.records).to eq([])
            expect(result.records.page).to eq(1)
            expect(result.records.per_page).to eq(25)
        end
    end

    it "未知のオプションを拒否する" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: "",
                        fields:  [:title],
                    },
                ],
                unknown: true,
            )
        end.to raise_error(ArgumentError, /未知の検索オプション/)
    end

    it "検証済みのElasticsearch値を変更せずbodyへ渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "検索語",
                    fields: {
                        title: 2.5,
                    },
                },
            ],
            sort: {
                status: "desc",
                count:  :asc,
            },
            aggs: {
                status_count: {
                    terms: {
                        field:         :status,
                        size:          10,
                        min_doc_count: 0,
                    },
                },
                count_ranges: {
                    range: {
                        field: :count,
                        ranges: [
                            { to: 10 },
                            { from: 10, to: 20, key: "middle" },
                            { from: 20 },
                        ],
                    },
                },
            },
            highlight: {
                fields: {
                    status: {
                        number_of_fragments: 0,
                    },
                },
                max_analyzed_offset: 0,
            },
            where: {
                count: {
                    range: {
                        gte: 0,
                    },
                },
            },
            where_not: {
                status: {
                    terms: ["deleted"],
                },
            },
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must, 0, :combined_fields, :fields)).to eq([
            "title^2.5",
        ])
        expect(body.dig(:query, :bool, :filter)).to include(
            {
                range: {
                    count: {
                        gte: 0,
                    },
                },
            },
            {
                bool: {
                    should: [
                        {
                            term: {
                                status: "published",
                            },
                        },
                    ],
                    minimum_should_match: 1,
                },
            },
        )
        expect(body.dig(:query, :bool, :must_not)).to eq([
            {
                terms: {
                    status: ["deleted"],
                },
            },
        ])
        expect(body[:sort]).to eq([
            {
                status: "desc",
            },
            {
                count: :asc,
            },
        ])
        expect(body.dig(:aggs, :status_count, :terms)).to eq(
            field:         :status,
            size:          10,
            min_doc_count: 0,
        )
        expect(body.dig(:aggs, :count_ranges, :range)).to eq(
            field: :count,
            ranges: [
                { to: 10 },
                { from: 10, to: 20, key: "middle" },
                { from: 20 },
            ],
        )
        expect(body[:highlight]).to include(
            fields: {
                status: {
                    number_of_fragments: 0,
                },
            },
            max_analyzed_offset: 0,
        )
    end

    it "aggsのArray形式をデフォルトbucket数付きtermsへ変換する" do
        expect(AreSearch.default_aggs_size).to eq(200)

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:title],
                },
            ],
            aggs: [:status, :count],
            dump_body: true,
        )

        expect(body[:aggs]).to eq(
            status: {
                terms: {
                    field: :status,
                    size:  AreSearch.default_aggs_size,
                },
            },
            count: {
                terms: {
                    field: :count,
                    size:  AreSearch.default_aggs_size,
                },
            },
        )
    end

    it "標準検索とMore Like This検索でwhere_orをfilter内のbool.shouldへ入れる" do
        standard_body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:title],
                },
            ],
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )
        mlt_body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title, :status],
                like: {
                    instance:     article,
                    index_target: article_index_target,
                },
            },
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )

        [standard_body, mlt_body].each do |body|
            where_or_bool = body.dig(:query, :bool, :filter).find do |filter_clause|
                filter_clause.key?(:bool)
            end

            expect(where_or_bool).to eq(
                bool: {
                    should: [
                        {
                            term: {
                                status: "published",
                            },
                        },
                    ],
                    minimum_should_match: 1,
                },
            )
        end
    end

    it "where系オプションを持ち、shouldを未知のオプションとして扱う" do
        expect(AreSearch::SearchOptionValidator::OPTION_DEFINITIONS.keys).to include(
            :where,
            :where_not,
            :where_or,
        )
        expect(AreSearch::SearchOptionValidator::OPTION_DEFINITIONS.keys).not_to include(:should)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                should: [],
            )
        end.to raise_error(ArgumentError, /未知の検索オプション/)
    end

    it "MLT固有パラメーターはmlt配下だけで受け付ける" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt: {
                    fields: [:title, :status],
                    like: {
                        instance:     article,
                        index_target: article_index_target,
                    },
                },
                minimum_should_match:  "50%",
                dump_body:             true,
            )
        end.to raise_error(ArgumentError, /未知の検索オプション/)

        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title, :status],
                like: {
                    instance:     article,
                    index_target: article_index_target,
                },
                minimum_should_match: "50%",
            },
            dump_body: true,
        )

        expect(
            body.dig(:query, :bool, :must, :more_like_this, :minimum_should_match),
        ).to eq("50%")
    end

    it "mappingsに無いフィールドを表記に関係なく拒否する" do
        search_fields = [
            :"title.keyword",
            :Title,
            :"title*",
        ]

        search_fields.each do |field_name|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "検索語",
                            fields:       [field_name],
                        },
                    ],
                    dump_body:    true,
                )
            end.to raise_error(ArgumentError, /any_text_without_non_text_fields/)
        end

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                where: {
                    :"OtherModel.secret" => {
                        term: "value",
                    },
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /opts\[:where\] に未知のキーがあります: :"OtherModel\.secret"/,
        )
    end

    it "STI子クラスのinstanceと上位モデルのindex targetをMore Like Thisに使用できる" do
        child_model = Class.new(article_model)
        child_instance = child_model.new

        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title],
                like: {
                    instance:     child_instance,
                    index_target: article_index_target,
                },
            },
            dump_body: true,
        )

        expect(
            body.dig(:query, :bool, :must, :more_like_this, :like),
        ).to eq([
            {
                _index: "test__articles__default",
                _id:    "1",
            },
        ])
    end

    it "instanceから取得したindex targetが指定されたindex targetと異なる場合は拒否する" do
        other_model = Class.new do
            attr_reader :id

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            def initialize
                @id = 2
            end
        end
        other_instance = other_model.new
        other_index_target = double(
            "other_index_target",
            are_search_index_alias_name: "test__documents__default",
        )

        allow(other_model)
            .to receive(:are_search_index_target)
            .with(:default)
            .and_return(other_index_target)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt: {
                    fields: [:title],
                    like: {
                        instance:     other_instance,
                        index_target: article_index_target,
                    },
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /mlt\.like\.instance から取得した index_target と mlt\.like\.index_target が一致していません/,
        )
    end

    it "More Like Thisのfieldsを検索先と基準index targetの両方で検証する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:status],
                like: {
                    instance:     article,
                    index_target: mlt_source_index_target,
                },
            },
            dump_body: true,
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt[:fields]).to eq(["status"])
        expect(mlt[:like]).to eq([
            {
                _index: "test__articles__mlt_source",
                _id:    "1",
            },
        ])

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt: {
                    fields: [:title],
                    like: {
                        instance:     article,
                        index_target: mlt_source_index_target,
                    },
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /mlt\.fields.*text または keyword.*:title/,
        )

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt: {
                    fields: [:body],
                    like: {
                        instance:     article,
                        index_target: mlt_source_index_target,
                    },
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /mlt\.fields.*_source.*store.*:body/,
        )
    end

    it "More Like Thisはmltの基準情報以外をmore_like_this句へ渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title, :status],
                like: {
                    instance:     article,
                    index_target: article_index_target,
                },
                min_term_freq:        0,
                min_doc_freq:         -1,
                max_query_terms:      0,
                min_word_length:      0,
                minimum_should_match: "ESで判定する値",
                boost_terms:          1,
                max_word_length:       30,
                include:               true,
                stop_words:            ["ruby", "rails"],
                per_field_analyzer: {
                    title:  "standard",
                    status: "keyword",
                },
            },
            dump_body: true,
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt[:fields]).to eq(["title", "status"])
        expect(mlt[:like]).to eq([
            {
                _index: "test__articles__default",
                _id:    "1",
            },
        ])
        expect(mlt[:min_term_freq]).to eq(0)
        expect(mlt[:min_doc_freq]).to eq(-1)
        expect(mlt[:max_query_terms]).to eq(0)
        expect(mlt[:min_word_length]).to eq(0)
        expect(mlt[:minimum_should_match]).to eq("ESで判定する値")
        expect(mlt[:boost_terms]).to eq(1)
        expect(mlt[:max_word_length]).to eq(30)
        expect(mlt[:include]).to eq(true)
        expect(mlt[:stop_words]).to eq(["ruby", "rails"])
        expect(mlt[:per_field_analyzer]).to eq(
            title:  "standard",
            status: "keyword",
        )
        expect(mlt).not_to have_key(:instance)
        expect(mlt).not_to have_key(:index_target)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt: {
                    fields: [:count],
                    like: {
                        instance:     article,
                        index_target: article_index_target,
                    },
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /any_text_or_keyword_without_other_type_fields/)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                mlt: {
                    instance:     article,
                    index_target: article_index_target,
                    fields:       [:title],
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /必要なキーがありません: \[:like\]/)
    end

    it "mltの省略値をMore Like This句へ設定する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title],
                like: {
                    instance:     article,
                    index_target: article_index_target,
                },
            },
            dump_body: true,
        )

        mlt = body.dig(:query, :bool, :must, :more_like_this)

        expect(mlt[:min_term_freq]).to eq(2)
        expect(mlt[:min_doc_freq]).to eq(5)
        expect(mlt[:max_query_terms]).to eq(25)
        expect(mlt).not_to have_key(:minimum_should_match)
        expect(mlt).not_to have_key(:boost_terms)
    end

    it "where_orとMLTのminimum_should_matchを別階層へ出力する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title],
                like: {
                    instance:     article,
                    index_target: article_index_target,
                },
                minimum_should_match: "50%",
            },
            where_or: {
                status: {
                    term: "published",
                },
            },
            dump_body: true,
        )

        where_or_bool = body.dig(:query, :bool, :filter).find do |filter_clause|
            filter_clause.key?(:bool)
        end

        expect(where_or_bool.dig(:bool, :minimum_should_match)).to eq(1)
        expect(
            body.dig(:query, :bool, :must, :more_like_this, :minimum_should_match),
        ).to eq("50%")
    end

    it "model_relationsに定義されていないnode_typeを拒否する" do
        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                model_relations: [],
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /node_type :array は定義されていません/,
        )
    end
end
