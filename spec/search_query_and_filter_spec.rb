# frozen_string_literal: true

require "spec_helper"

RSpec.describe "query builder fields" do
    let(:article_model) do
        Class.new do
            # Searcherがモデル識別条件を作成できるよう固定名を返す。
            def self.name
                "Article"
            end

            # QueryBuilderの検査に必要なSearchable判定だけを成立させる。
            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end
        end
    end

    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                       article_model,
            index_target_name:                       :default,
            are_search_index_alias_name:          "test__articles__default",
            are_search_index_alias_exists?: true,
            are_search_index_mappings:            {
                properties: {
                    title: { type: "text" },
                    body:  { type: "text" },
                },
            },
            are_search_index_settings: { max_result_window: 2_000 },
        )
    end

    it "queriesの空Arrayで標準検索を選択し全文検索句を作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [],
            dump_body: true,
        )

        expect(body.dig(:query, :bool)).not_to have_key(:must)
    end

    it "空の標準検索オプションをElasticsearch bodyへ追加しない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [],
            runtime_mappings: {},
            where: {},
            model_relations: {},
            sort: {},
            aggs: [],
            suggest: {},
            highlight: {},
            response: {},
            dump_body: true,
        )

        [:runtime_mappings, :sort, :aggs, :suggest, :highlight, :fields, :stored_fields, :docvalue_fields].each do |key|
            expect(body).not_to have_key(key)
        end
    end

    it "空のraw_bodyはRaw検索としてページングだけを追加する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            raw_body: {},
            dump_body: true,
        )

        expect(body).to eq(
            from: 0,
            size: 25,
        )
    end

    it "1件の標準検索のArray形式をcombined_fieldsへ変換する" do
        source_fields = [:title, :body]

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       source_fields,
                },
            ],
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :combined_fields, :fields),
        ).to eq([
            "title",
            "body",
        ])
        expect(source_fields).to eq([:title, :body])
    end

    it "1件の標準検索のHash形式をboost付きcombined_fieldsへ変換する" do
        source_fields = {
            title: 2.0,
            body:  1,
        }

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       source_fields,
                },
            ],
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :combined_fields, :fields),
        ).to eq([
            "title^2.0",
            "body^1",
        ])
        expect(source_fields).to eq(
            title: 2.0,
            body:  1,
        )
    end


    it "query_typeでsimple_query_stringへ切り替える" do
        query_string = 'Ruby + (Rails | Elasticsearch) -"Java VM"'

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: query_string,
                    fields: {
                        title: 2.0,
                        body:  1,
                    },
                    query_type: AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                simple_query_string: {
                    query:            query_string,
                    fields:           ["title^2.0", "body^1"],
                    default_operator: "and",
                    flags:            "AND|OR|NOT|PHRASE|PRECEDENCE|WHITESPACE|ESCAPE",
                },
            },
        ])
    end

    it "simple_query_stringの検索文字列を変換せずそのまま渡す" do
        query_string = 'C++ AND A|B OR -draft OR path\\name OR "Ruby on Rails"'

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: query_string,
                    fields:       [:title],
                    query_type:   AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                },
            ],
            dump_body:    true,
        )

        expect(
            body.dig(:query, :bool, :must, 0, :simple_query_string, :query),
        ).to eq(query_string)
    end

    it "queries配下でquery_typeを個別に指定する" do
        simple_query = 'Ruby | "Ruby on Rails"'

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
                {
                    query_string: simple_query,
                    fields:       [:title, :body],
                    query_type:   AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title"],
                    operator: "and",
                },
            },
            {
                simple_query_string: {
                    query:            simple_query,
                    fields:           ["title", "body"],
                    default_operator: "and",
                    flags:            "AND|OR|NOT|PHRASE|PRECEDENCE|WHITESPACE|ESCAPE",
                },
            },
        ])
    end

    it "queries配下の空文字列と空白だけの検索語は全文検索句を作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
                {
                    query_string: "   ",
                    fields:       [:body],
                },
                {
                    query_string: "Rails",
                    fields:       [:title, :body],
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title", "body"],
                    operator: "and",
                },
            },
        ])
    end

    it "queries配下の検索語がすべて空の場合はmustを作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
                {
                    query_string: "   ",
                    fields:       [:body],
                },
            ],
            dump_body: true,
        )

        expect(body.dig(:query, :bool)).not_to have_key(:must)
    end

    it "queries配下のArray形式とHash形式を個別に変換する" do
        source_queries = [
            {
                query_string: "Rails",
                fields: [:title, :body],
            },
            {
                query_string: "Ruby",
                fields: {
                    title: 3.0,
                    body:  1,
                },
            },
        ]

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries:   source_queries,
            dump_body: true,
        )

        expect(body.dig(:query, :bool, :must)).to eq([
            {
                combined_fields: {
                    query:    "Rails",
                    fields:   ["title", "body"],
                    operator: "and",
                },
            },
            {
                combined_fields: {
                    query:    "Ruby",
                    fields:   ["title^3.0", "body^1"],
                    operator: "and",
                },
            },
        ])
        expect(source_queries[0][:fields]).to eq([:title, :body])
        expect(source_queries[1][:fields]).to eq(
            title: 3.0,
            body:  1,
        )
    end

    it "suggestをElasticsearch形式のままbodyへ渡す" do
        source_suggest = {
            title_spell: {
                text: "cofee markt",
                term: {
                    field:        :title,
                    size:         5,
                    suggest_mode: :always,
                },
            },
        }

        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:       [:title],
                },
            ],
            suggest:   source_suggest,
            dump_body: true,
        )

        expect(body[:suggest]).to eq(source_suggest)
        expect(source_suggest.dig(:title_spell, :term, :field)).to eq(:title)
    end

    it "suggestのterm・phrase・completionは存在しないfieldを拒否する" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        [:term, :phrase, :completion].each do |suggester_type|
            expect do
                AreSearch::Searcher.search(
                    [article_index_target],
                    queries: [
                        {
                            query_string: "",
                            fields:       [:title],
                        },
                    ],
                    suggest: {
                        test_suggest: {
                            text: "cofee",
                            suggester_type => {
                                field: :unknown,
                            },
                        },
                    },
                    dump_body: true,
                )
            end.to raise_error(ArgumentError, /unknown/)
        end
    end

end

RSpec.describe "search highlight" do
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
                    status: { type: "keyword" },
                    count:  { type: "integer" },
                }
            end

            def initialize
                @id = 1
            end
        end
    end

    let(:document_model) do
        Class.new do
            def self.name
                "Document"
            end

            def self.are_search_ar_table_name
                "documents"
            end

            def self.include?(mod)
                return true if mod == AreSearch::Searchable

                super
            end

            def self.default_properties
                {
                    title:  { type: "text" },
                    body:   { type: "text" },
                    status: { type: "keyword" },
                }
            end
        end
    end

    let(:article) do
        article_model.new
    end

    let(:article_index_target) do
        AreSearch::IndexTarget.new(article_model, :default)
    end

    let(:document_index_target) do
        AreSearch::IndexTarget.new(document_model, :default)
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
            },
            "Document" => {
                default: {
                    settings: {
                        max_result_window: 2_000,
                    },
                    mappings: {},
                    properties_method: :default_properties,
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
            .with(index_alias_name: "test__documents__default")
            .and_return(true)
    end

    it "highlight未指定時はhighlight bodyを作らない" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields:    [:title, :body],
                },
            ],
            dump_body: true,
        )

        expect(body).not_to have_key(:highlight)
    end

    it "highlightにはfieldsを必須とする" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:title, :body],
                    },
                ],
                highlight: {
                    fragment_size: 150,
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /必要なキー.*fields/)
    end

    it "fieldsのArray形式を空オプションのHashへ変換する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:title, :body],
                },
            ],
            highlight: {
                fields: [:title, :body],
                type: "unified",
                require_field_match: false,
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            type: "unified",
            require_field_match: false,
            fields: {
                title: {},
                body:  {},
            },
        )
    end

    it "fieldsのHash形式はフィールド別オプションを保持する" do
        body = AreSearch::Searcher.search(
            [article_index_target, document_index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:title, :body],
                },
            ],
            highlight: {
                fields: {
                    body: {
                        fragment_size: 150,
                        number_of_fragments: 3,
                    },
                    status: {
                        number_of_fragments: 0,
                    },
                },
                max_analyzed_offset: 1_000_000,
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            max_analyzed_offset: 1_000_000,
            fields: {
                body: {
                    fragment_size: 150,
                    number_of_fragments: 3,
                },
                status: {
                    number_of_fragments: 0,
                },
            },
        )
    end

    it "fieldsのHash形式では空のフィールドオプションを受け付ける" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:title],
                },
            ],
            highlight: {
                fields: {
                    title: {},
                },
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fields: {
                title: {},
            },
        )
    end

    it "fields以外のElasticsearchパラメーターを加工せず渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields: [:title],
                },
            ],
            highlight: {
                fields: {
                    title: {
                        matched_fields: [:title, :body],
                    },
                },
                pre_tags: ["<mark>"],
                post_tags: ["</mark>"],
                options: {
                    custom: [1, true, nil],
                },
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fields: {
                title: {
                    matched_fields: [:title, :body],
                },
            },
            pre_tags: ["<mark>"],
            post_tags: ["</mark>"],
            options: {
                custom: [1, true, nil],
            },
        )
    end

    it "textまたはkeyword以外のフィールドをhighlight対象にできない" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        expect do
            AreSearch::Searcher.search(
                [article_index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:title],
                    },
                ],
                highlight: {
                    fields: {
                        count: {
                            number_of_fragments: 0,
                        },
                    },
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /opts\[:highlight\]\[fields\] に未知のキーがあります: :count/,
        )
    end

    it "More Like This検索でも同じhighlight定義を使用する" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            mlt: {
                fields: [:title],
                like: {
                    instance:     article,
                    index_target: article_index_target,
                },
            },
            highlight: {
                fields: [:body, :status],
                fragment_size: 150,
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fragment_size: 150,
            fields: {
                body:   {},
                status: {},
            },
        )
    end
    it "pre_tags・post_tags・encoderをそのまま渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            highlight: {
                fields:    [:title],
                pre_tags:  ["<mark>"],
                post_tags: ["</mark>"],
                encoder:   "default",
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fields: {
                title: {},
            },
            pre_tags:  ["<mark>"],
            post_tags: ["</mark>"],
            encoder:   "default",
        )
    end

    it "フィールド別のpre_tags・post_tagsをそのまま渡す" do
        body = AreSearch::Searcher.search(
            [article_index_target],
            queries: [
                {
                    query_string: "Rails",
                    fields:       [:title],
                },
            ],
            highlight: {
                fields: {
                    title: {
                        pre_tags:  ["<strong>"],
                        post_tags: ["</strong>"],
                    },
                },
            },
            dump_body: true,
        )

        expect(body[:highlight]).to eq(
            fields: {
                title: {
                    pre_tags:  ["<strong>"],
                    post_tags: ["</strong>"],
                },
            },
        )
    end
end

RSpec.describe AreSearch::Searcher, "filters" do
    let(:model_class) do
        AreSearch::SyncRequest
    end

    let(:index_target) do
        double(
            "index_target",
            model_class:                       model_class,
            index_target_name:                 :default,
            are_search_index_alias_name:       "test__sync_requests__default",
            are_search_index_alias_exists?:    true,
            are_search_index_mappings:         {
                properties: {
                    search_text:         { type: "text" },
                    ar_model_class_name: { type: "keyword" },
                    index_target_name:   { type: "keyword" },
                    retry_count:         { type: "integer" },
                    score:               { type: "float" },
                },
            },
            are_search_index_settings: {
                max_result_window: 2_000,
            },
        )
    end

    let(:client) do
        double("client")
    end

    before do
        allow(model_class)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
    end

    # トップレベルfilter内に置かれた利用側whereのbool句を返す。
    def where_bool_clause(body)
        body.dig(:query, :bool, :filter).find do |filter_clause|
            filter_clause.key?(:bool)
        end
    end

    it "whereの4節とminimum_should_matchをfilter内boolへ組み立てる" do
        body = described_class.search(
            [index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:search_text],
                },
            ],
            where: {
                must: [
                    { retry_count: { term: 0 } },
                ],
                filter: [
                    { index_target_name: { terms: ["default", "archive"] } },
                ],
                should: [
                    {
                        score: {
                            range: {
                                gte: 1.0,
                                lt:  2.0,
                            },
                        },
                    },
                ],
                must_not: [
                    { ar_model_class_name: { term: "Blocked" } },
                ],
                minimum_should_match: 1,
            },
            dump_body: true,
        )

        expect(where_bool_clause(body)).to eq(
            bool: {
                must: [
                    { term: { retry_count: 0 } },
                ],
                filter: [
                    { terms: { index_target_name: ["default", "archive"] } },
                ],
                should: [
                    {
                        range: {
                            score: {
                                gte: 1.0,
                                lt:  2.0,
                            },
                        },
                    },
                ],
                must_not: [
                    { term: { ar_model_class_name: "Blocked" } },
                ],
                minimum_should_match: 1,
            },
        )
    end

    it "whereのboolを再帰して(A AND B) OR Cの構造を維持する" do
        body = described_class.search(
            [index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:search_text],
                },
            ],
            where: {
                should: [
                    {
                        bool: {
                            filter: [
                                { retry_count: { term: 0 } },
                                { index_target_name: { term: "default" } },
                            ],
                        },
                    },
                    {
                        retry_count: {
                            range: {
                                gte: 1,
                                lt:  10,
                            },
                        },
                    },
                ],
                minimum_should_match: 1,
            },
            dump_body: true,
        )

        expect(where_bool_clause(body)).to eq(
            bool: {
                should: [
                    {
                        bool: {
                            filter: [
                                { term: { retry_count: 0 } },
                                { term: { index_target_name: "default" } },
                            ],
                        },
                    },
                    {
                        range: {
                            retry_count: {
                                gte: 1,
                                lt:  10,
                            },
                        },
                    },
                ],
                minimum_should_match: 1,
            },
        )
    end

    it "termの値が制約に合わない場合はparams_invalidの空結果を返す" do
        [[], {}].each do |value|
            result = described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        { retry_count: { term: value } },
                    ],
                },
                dump_body: true,
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
            expect(result.records).to eq([])
        end
    end

    it "termsの値が制約に合わない場合はparams_invalidの空結果を返す" do
        invalid_values = [
            "default",
            ["default", {}],
        ]

        invalid_values.each do |value|
            result = described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        { index_target_name: { terms: value } },
                    ],
                },
                dump_body: true,
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
            expect(result.records).to eq([])
        end
    end

    it "termsの空Arrayを許可する" do
        body = described_class.search(
            [index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:search_text],
                },
            ],
            where: {
                filter: [
                    { index_target_name: { terms: [] } },
                ],
            },
            dump_body: true,
        )

        expect(where_bool_clause(body)).to eq(
            bool: {
                filter: [
                    { terms: { index_target_name: [] } },
                ],
            },
        )
    end

    it "term、terms、rangeはFloatを受け付ける" do
        body = described_class.search(
            [index_target],
            queries: [
                {
                    query_string: "",
                    fields: [:search_text],
                },
            ],
            where: {
                filter: [
                    { score: { term: 1.5 } },
                    { score: { terms: [1.5, 2.5] } },
                    {
                        score: {
                            range: {
                                gte: 1.5,
                                lt:  2.5,
                            },
                        },
                    },
                ],
            },
            dump_body: true,
        )

        expect(where_bool_clause(body)).to eq(
            bool: {
                filter: [
                    { term: { score: 1.5 } },
                    { terms: { score: [1.5, 2.5] } },
                    {
                        range: {
                            score: {
                                gte: 1.5,
                                lt:  2.5,
                            },
                        },
                    },
                ],
            },
        )
    end

    it "rangeの値が制約に合わない場合はparams_invalidの空結果を返す" do
        [1..10, {}, { gte: [1] }].each do |value|
            result = described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        { retry_count: { range: value } },
                    ],
                },
                dump_body: true,
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
            expect(result.records).to eq([])
        end
    end

    it "whereの旧Array形式とfieldの旧省略形式を拒否する" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        expect do
            described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: [
                    { retry_count: { term: 0 } },
                ],
                dump_body: true,
            )
        end.to raise_error(ArgumentError)

        expect do
            described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        { retry_count: 0 },
                    ],
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError)
    end

    it "各fieldにterm、terms、rangeのいずれか1つだけを要求する" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        expect do
            described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        { retry_count: { match: 0 } },
                    ],
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError)

        expect do
            described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        {
                            retry_count: {
                                term: 0,
                                terms: [0, 1],
                            },
                        },
                    ],
                },
                dump_body: true,
            )
        end.to raise_error(ArgumentError, /1 件/)
    end

    it "text型フィールドをwhere条件に使用できない" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        expect do
            described_class.search(
                [index_target],
                queries: [
                    {
                        query_string: "",
                        fields: [:search_text],
                    },
                ],
                where: {
                    filter: [
                        { search_text: { term: "Rails" } },
                    ],
                },
                dump_body: true,
            )
        end.to raise_error(
            ArgumentError,
            /opts\[:where\]\[filter\]\[0\] に未知のキーがあります: :search_text/,
        )
    end
end

RSpec.describe AreSearch::Searcher do
    let(:model_class) do
        double(
            "Article",
            name: "Article",
        )
    end

    let(:index_target) do
        double(
            "index_target",
            model_class: model_class,
            are_search_index_settings: { max_result_window: 2_000 },
        )
    end

    before do
        allow(model_class)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)
    end

    it "ESパラメーターが不正なら既定ページの空結果を返す" do
        valid_options = {
            sort: [
                {
                    _script: {
                        type: :number,
                        script: {
                            source: "doc['score'].value",
                        },
                        order: :desc,
                    },
                },
            ],
            page: 3,
            per_page: 10,
        }

        allow(AreSearch::SearchParamValidator)
            .to receive(:validate!)
            .with(
                [index_target],
                [model_class],
                2_000,
                sort: valid_options[:sort],
                page: 3,
                per_page: 10,
            )
            .and_return(valid_options)

        expect(described_class).not_to receive(:index_ready?)

        query_builder = double("query_builder")
        body_builder = double("body_builder")
        query_options = valid_options.dup
        body_options = valid_options.dup
        query = { match_all: {} }
        body = {
            query: query,
            sort: valid_options[:sort],
        }

        expect(AreSearch::QueryBuilderSelector)
            .to receive(:select)
            .with(valid_options)
            .and_return(query_builder)

        expect(query_builder)
            .to receive(:build)
            .with([index_target], kind_of(Hash)) do |_index_targets, actual_options|
                actual_options.clear
                query
            end

        expect(AreSearch::BodyBuilderSelector)
            .to receive(:select)
            .with(valid_options)
            .and_return(body_builder)

        expect(body_builder)
            .to receive(:build)
            .with([index_target], query, kind_of(Hash), 2_000) do |_index_targets, _query, actual_options|
                actual_options.clear
                body
            end

        expect(AreSearch.search_body_policy)
            .to receive(:valid?)
            .with(body)
            .and_return(false)

        expect(AreSearch).not_to receive(:client)

        result = described_class.search(
            [index_target],
            sort: valid_options[:sort],
            page: 3,
            per_page: 10,
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(result.records).to eq([])
        expect(result.records.page).to eq(1)
        expect(result.records.per_page).to eq(25)
        expect(result.total_count).to eq(0)
        expect(result.records.total_count).to eq(0)
    end

    it "検索param policyに拒否された場合は検索前にparams_invalid空結果を返す" do
        valid_options = {
            queries: [
                {
                    query_string: "a" * 2049,
                    fields: [:title],
                },
            ],
        }

        allow(AreSearch::SearchParamValidator)
            .to receive(:validate!)
            .and_return(valid_options)

        expect(AreSearch.search_param_policy)
            .to receive(:validate!)
            .with(valid_options)
            .and_raise(AreSearch::InvalidSearchOption)

        expect(AreSearch::QueryBuilderSelector).not_to receive(:select)
        expect(AreSearch::BodyBuilderSelector).not_to receive(:select)
        expect(AreSearch).not_to receive(:client)

        result = described_class.search(
            [index_target],
            queries: valid_options[:queries],
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
        expect(result.records).to eq([])
    end

    it "AreSearchパラメーターの検証エラーは空結果へ変換しない" do
        allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

        allow(AreSearch::SearchParamValidator)
            .to receive(:validate!)
            .and_raise(ArgumentError, "invalid option")

        expect(AreSearch::SearchBodyPolicy).not_to receive(:valid?)

        expect do
            described_class.search(
                [index_target],
                unknown: true,
            )
        end.to raise_error(ArgumentError, "invalid option")
    end
end
