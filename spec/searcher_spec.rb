# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::Searcher do
    let(:article_model) do
        class_double("Article", name: "Article")
    end
    let(:document_model) do
        class_double("Document", name: "Document")
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
                },
            },
            are_search_index_settings: { max_result_window: 2_000 },
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                       document_model,
            index_target_name:                       :default,
            are_search_index_alias_name:          "test__documents__default",
            are_search_index_alias_exists?: true,
            are_search_index_mappings:            {
                properties: {
                    name: { type: "text" },
                },
            },
            are_search_index_settings: { max_result_window: 2_000 },
        )
    end

    describe ".check_index_exists?" do
        it "全 index target の alias が存在すれば true を返す" do
            expect(article_index_target)
                .to receive(:are_search_index_alias_exists?)
                .and_return(true)
            expect(document_index_target)
                .to receive(:are_search_index_alias_exists?)
                .and_return(true)

            result = described_class.check_index_exists?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(true)
        end

        it "ひとつでも alias が無ければ false を返す" do
            allow(article_index_target)
                .to receive(:are_search_index_alias_exists?)
                .and_return(true)
            allow(document_index_target)
                .to receive(:are_search_index_alias_exists?)
                .and_return(false)

            result = described_class.check_index_exists?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(false)
        end
    end

    describe ".index_ready?" do
        it "全 alias が存在すれば true を返す" do
            expect(described_class)
                .to receive(:check_index_exists?)
                .with([
                    article_index_target,
                    document_index_target,
                ])
                .and_return(true)

            result = described_class.index_ready?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(true)
        end

        it "alias が無ければ false を返す" do
            expect(described_class)
                .to receive(:check_index_exists?)
                .with([article_index_target])
                .and_return(false)

            result = described_class.index_ready?([article_index_target])

            expect(result).to eq(false)
        end

        it "状態確認で例外が出た場合は false を返す" do
            allow(described_class)
                .to receive(:check_index_exists?)
                .and_raise(RuntimeError, "failed")

            result = described_class.index_ready?([article_index_target])

            expect(result).to eq(false)
        end
    end


    describe ".search status" do
        around do |example|
            original_search_failure_mode = AreSearch.search_failure_mode
            AreSearch.search_failure_mode = :empty_result

            example.run
        ensure
            AreSearch.search_failure_mode = original_search_failure_mode
        end

        it "検索パラメーターが不正ならデフォルトページのparams_invalid空結果を返す" do
            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with([article_index_target], [article_model], 2_000, page: "2")
                .and_raise(AreSearch::InvalidSearchOption, "opts[:page] は正の整数で指定してください")

            expect(AreSearch::QueryBuilderSelector).not_to receive(:select)
            expect(AreSearch::BodyBuilderSelector).not_to receive(:select)
            expect(AreSearch.search_body_policy).not_to receive(:valid?)
            expect(AreSearch).not_to receive(:client)

            result = described_class.search(
                [article_index_target],
                page: "2",
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
            expect(result.records).to eq([])
            expect(result.records.page).to eq(1)
            expect(result.records.per_page).to eq(25)
            expect(result.total_count).to eq(0)
            expect(result.records.total_count).to eq(0)
            expect(result.records_with_hit).to eq([])
        end

        it "search_failure_modeがempty_resultなら一般例外をログに記録してsearch_fail空結果を返す" do
            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with([article_index_target], [article_model], 2_000)
                .and_raise(RuntimeError, "unexpected search failure")

            expect(AreSearch.logger)
                .to receive(:error)
                .with("[search fail: RuntimeError]\nunexpected search failure")

            result = described_class.search([article_index_target])

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_SEARCH_FAIL)
            expect(result.records).to eq([])
            expect(result.records.page).to eq(1)
            expect(result.records.per_page).to eq(25)
            expect(result.total_count).to eq(0)
            expect(result.records.total_count).to eq(0)
            expect(result.records_with_hit).to eq([])
        end

        it "search_failure_modeがraiseなら検索パラメーター不正を例外にする" do
            AreSearch.search_failure_mode = :raise

            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with([article_index_target], [article_model], 2_000, page: "2")
                .and_raise(AreSearch::InvalidSearchOption, "opts[:page] は正の整数で指定してください")

            expect do
                described_class.search(
                    [article_index_target],
                    page: "2",
                )
            end.to raise_error(AreSearch::InvalidSearchOption, /正の整数/)
        end

        it "検索body policyに拒否された場合はparams_invalid空結果を返す" do
            queries = [
                {
                    query_string: "Rails",
                    fields: [:title],
                },
            ]
            valid_options = {
                queries: queries,
            }

            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with(
                    [article_index_target],
                    [article_model],
                    2_000,
                    queries: queries,
                )
                .and_return(valid_options)

            allow(AreSearch.search_body_policy)
                .to receive(:valid?)
                .and_return(false)

            expect(described_class).not_to receive(:index_ready?)
            expect(AreSearch).not_to receive(:client)

            result = described_class.search(
                [article_index_target],
                queries: queries,
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_PARAMS_INVALID)
            expect(result.records).to eq([])
        end

        it "search_failure_modeがraiseなら検索body policyの拒否を例外にする" do
            AreSearch.search_failure_mode = :raise

            queries = [
                {
                    query_string: "Rails",
                    fields: [:title],
                },
            ]
            valid_options = {
                queries: queries,
            }

            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with(
                    [article_index_target],
                    [article_model],
                    2_000,
                    queries: queries,
                )
                .and_return(valid_options)

            allow(AreSearch.search_body_policy)
                .to receive(:valid?)
                .and_return(false)

            expect(described_class).not_to receive(:index_ready?)
            expect(AreSearch).not_to receive(:client)

            expect do
                described_class.search(
                    [article_index_target],
                    queries: queries,
                )
            end.to raise_error(AreSearch::InvalidSearchBody, /search_body_policy/)
        end

        it "検索実行でindex不存在例外が出た場合はsearch_fail空結果を返す" do
            queries = [
                {
                    query_string: "Rails",
                    fields: [:title],
                },
            ]
            valid_options = {
                queries: queries,
            }

            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with(
                    [article_index_target],
                    [article_model],
                    2_000,
                    queries: queries,
                )
                .and_return(valid_options)

            expect(described_class).not_to receive(:index_ready?)
            expect(AreSearch::EsAdapter)
                .to receive(:no_validation_search)
                .with(
                    index: "test__articles__default",
                    body: kind_of(Hash),
                )
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)
            allow(AreSearch.logger).to receive(:error)

            result = described_class.search(
                [article_index_target],
                queries: queries,
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_SEARCH_FAIL)
            expect(result.records).to eq([])
            expect(result.records.page).to eq(1)
            expect(result.records.per_page).to eq(25)
            expect(result.total_count).to eq(0)
            expect(result.records.total_count).to eq(0)
            expect(result.records_with_hit).to eq([])
        end

        it "search_failure_modeがraiseならindex不存在の元例外を送出する" do
            AreSearch.search_failure_mode = :raise

            queries = [
                {
                    query_string: "Rails",
                    fields: [:title],
                },
            ]
            valid_options = {
                queries: queries,
            }

            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with(
                    [article_index_target],
                    [article_model],
                    2_000,
                    queries: queries,
                )
                .and_return(valid_options)

            expect(described_class).not_to receive(:index_ready?)
            expect(AreSearch::EsAdapter)
                .to receive(:no_validation_search)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            expect do
                described_class.search(
                    [article_index_target],
                    queries: queries,
                )
            end.to raise_error(Elastic::Transport::Transport::Errors::NotFound)
        end

        it "MLT基準 index 不存在も実検索の失敗としてsearch_fail空結果を返す" do
            mlt_options = {
                fields: [:name],
                like: {
                    instance:     double("document", id: 1),
                    index_target: document_index_target,
                },
            }
            valid_options = {
                mlt: mlt_options,
            }

            allow(article_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            expect(AreSearch::SearchParamValidator)
                .to receive(:validate!)
                .with(
                    [article_index_target],
                    [article_model],
                    2_000,
                    mlt: mlt_options,
                )
                .and_return(valid_options)

            expect(described_class).not_to receive(:index_ready?)
            expect(AreSearch::EsAdapter)
                .to receive(:no_validation_search)
                .with(
                    index: "test__articles__default",
                    body: kind_of(Hash),
                )
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)
            allow(AreSearch.logger).to receive(:error)

            result = described_class.search([article_index_target], mlt: mlt_options)

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_SEARCH_FAIL)
            expect(result.records).to eq([])
            expect(result.records.page).to eq(1)
            expect(result.records.per_page).to eq(25)
            expect(result.total_count).to eq(0)
            expect(result.records.total_count).to eq(0)
            expect(result.records_with_hit).to eq([])
        end

        it "未定義のstatusは拒否する" do
            expect do
                described_class.send(
                    :empty_search_result,
                    1,
                    25,
                    status: :unknown,
                )
            end.to raise_error(
                ArgumentError,
                "未知の検索結果statusです: :unknown",
            )
        end
    end


    describe "検索対象 index target 検証" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "同じindex targetを複数指定した場合は拒否する" do
            allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

            model = Class.new do
                def self.are_search_ar_table_name
                    "articles"
                end
            end
            allow(AreSearch::IndexTarget)
                .to receive(:searchable_class_setting_for)
                .with(model)
                .and_return(default: {})

            first_index_target = AreSearch::IndexTarget.new(model, :default)
            second_index_target = AreSearch::IndexTarget.new(model, :default)

            expect do
                described_class.search([
                    first_index_target,
                    second_index_target,
                ])
            end.to raise_error(
                ArgumentError,
                "同じ index target は複数指定できません",
            )
        end

        it "同じaliasを使う親子targetを同時指定した場合は拒否する" do
            allow(AreSearch).to receive(:search_failure_mode).and_return(:raise)

            parent_model = Class.new do
                def self.are_search_ar_table_name
                    "articles"
                end
            end
            child_model = Class.new(parent_model)

            allow(parent_model).to receive(:name).and_return("Article")
            allow(child_model).to receive(:name).and_return("SpecialArticle")
            allow(parent_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)
            allow(child_model)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            allow(AreSearch::IndexTarget)
                .to receive(:searchable_class_setting_for)
                .with(parent_model)
                .and_return(default: {})
            allow(AreSearch::IndexTarget)
                .to receive(:searchable_class_setting_for)
                .with(child_model)
                .and_return(default: {})

            parent_index_target = AreSearch::IndexTarget.new(parent_model, :default)
            child_index_target = AreSearch::IndexTarget.new(child_model, :default)

            expect do
                described_class.search([
                    parent_index_target,
                    child_index_target,
                ])
            end.to raise_error(
                ArgumentError,
                /同じ Elasticsearch index に親子関係のあるモデルを同時指定できません/,
            )
        end

        it "同じ alias の親子モデルは同時指定を拒否する" do
            parent_model = Class.new
            child_model = Class.new(parent_model)

            allow(parent_model).to receive(:name).and_return("Article")
            allow(child_model).to receive(:name).and_return("SpecialArticle")

            parent_index_target = double(
                "parent_index_target",
                model_class:              parent_model,
                are_search_index_alias_name: "test__articles__default",
            )
            child_index_target = double(
                "child_index_target",
                model_class:              child_model,
                are_search_index_alias_name: "test__articles__default",
            )

            expect do
                described_class.send(
                    :verify_no_parent_child_index_targets!,
                    [parent_index_target, child_index_target],
                )
            end.to raise_error(
                ArgumentError,
                /同じ Elasticsearch index に親子関係のあるモデルを同時指定できません/,
            )
        end

        it "異なる alias の親子モデルは同時指定を許可する" do
            parent_model = Class.new
            child_model = Class.new(parent_model)

            parent_index_target = double(
                "parent_index_target",
                model_class:              parent_model,
                are_search_index_alias_name: "test__articles__default",
            )
            child_index_target = double(
                "child_index_target",
                model_class:              child_model,
                are_search_index_alias_name: "test__special_articles__default",
            )

            expect do
                described_class.send(
                    :verify_no_parent_child_index_targets!,
                    [parent_index_target, child_index_target],
                )
            end.not_to raise_error
        end

        it "同じ alias の兄弟モデルは同時指定を許可する" do
            parent_model = Class.new
            first_child_model = Class.new(parent_model)
            second_child_model = Class.new(parent_model)

            first_index_target = double(
                "first_index_target",
                model_class:              first_child_model,
                are_search_index_alias_name: "test__articles__default",
            )
            second_index_target = double(
                "second_index_target",
                model_class:              second_child_model,
                are_search_index_alias_name: "test__articles__default",
            )

            expect do
                described_class.send(
                    :verify_no_parent_child_index_targets!,
                    [first_index_target, second_index_target],
                )
            end.not_to raise_error
        end
    end

    describe "index target 解決" do
        it "alias 名だけを index_target に対応付ける" do
            result = described_class.send(
                :build_index_to_index_targets,
                [article_index_target, document_index_target],
            )

            expect(result).to eq(
                "test__articles__default"  => [article_index_target],
                "test__documents__default" => [document_index_target],
            )
        end


        it "同じ alias の兄弟モデルは候補として並べる" do
            parent_model = Class.new
            first_child_model = Class.new(parent_model)
            second_child_model = Class.new(parent_model)

            allow(first_child_model).to receive(:name).and_return("FirstArticle")
            allow(second_child_model).to receive(:name).and_return("SecondArticle")

            first_index_target = double(
                "first_index_target",
                model_class:              first_child_model,
                are_search_index_alias_name: "test__articles__default",
            )
            second_index_target = double(
                "second_index_target",
                model_class:              second_child_model,
                are_search_index_alias_name: "test__articles__default",
            )

            result = described_class.send(
                :build_index_to_index_targets,
                [first_index_target, second_index_target],
            )

            expect(result).to eq(
                "test__articles__default" => [
                    first_index_target,
                    second_index_target,
                ],
            )
        end

        it "物理 index 名を alias 名へ戻して index_target を返す" do
            index_to_target = described_class.send(
                :build_index_to_index_targets,
                [article_index_target],
            )

            result = described_class.send(
                :index_targets_for_hit_index,
                index_to_target,
                "test__articles__default__2026_07_03_03_10_00_123456",
            )

            expect(result).to eq([article_index_target])
        end

        it "timestamp 形式でない未知 index は nil を返す" do
            index_to_target = described_class.send(
                :build_index_to_index_targets,
                [article_index_target],
            )

            result = described_class.send(
                :index_targets_for_hit_index,
                index_to_target,
                "test__articles__default__20260703031000",
            )

            expect(result).to eq(nil)
        end
    end

    describe "result build" do
        it "予約フィールドのモデル名に対象モデルを含む hit だけ復元する" do
            record = double("article", id: 1)
            hits = [
                {
                    "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                    "_id" => "1",
                    "_source" => {
                        AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "SpecialArticle",
                            "Article",
                        ],
                        AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                    },
                },
                {
                    "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                    "_id" => "2",
                    "_source" => {
                        AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "Document",
                        ],
                        AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME.to_s => "2",
                    },
                },
            ]

            expect(article_model)
                .to receive(:where)
                .with(id: ["1"])
                .and_return([record])

            result = described_class.send(
                :build_records_results,
                hits,
                { "test__articles__default" => [article_index_target] },
                {},
            )

            expect(result).to eq(
                records: [record],
                records_with_hit: [
                    [
                        record,
                        {
                            index: "test__articles__default__2026_07_03_03_10_00_123456",
                            id: "1",
                            source: {
                                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME => [
                                    "SpecialArticle",
                                    "Article",
                                ],
                                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME => "1",
                            },
                            highlight: {},
                            fields: {},
                            index_target_name: :default,
                        },
                    ],
                ],
            )
        end


        it "同じ alias の兄弟モデルを予約フィールドのモデル名で振り分ける" do
            parent_model = Class.new
            first_child_model = Class.new(parent_model)
            second_child_model = Class.new(parent_model)
            first_record = double("first_record", id: 1)
            second_record = double("second_record", id: 2)

            allow(first_child_model).to receive(:name).and_return("FirstArticle")
            allow(second_child_model).to receive(:name).and_return("SecondArticle")

            first_index_target = double(
                "first_index_target",
                model_class:                  first_child_model,
                index_target_name:                  :default,
                are_search_index_alias_name:     "test__articles__default",
            )
            second_index_target = double(
                "second_index_target",
                model_class:                  second_child_model,
                index_target_name:                  :default,
                are_search_index_alias_name:     "test__articles__default",
            )

            expect(first_child_model)
                .to receive(:where)
                .with(id: ["1"])
                .and_return([first_record])
            expect(second_child_model)
                .to receive(:where)
                .with(id: ["2"])
                .and_return([second_record])

            hits = [
                {
                    "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                    "_id" => "1",
                    "_source" => {
                        AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "FirstArticle",
                        ],
                    },
                },
                {
                    "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                    "_id" => "2",
                    "_source" => {
                        AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "SecondArticle",
                        ],
                    },
                },
            ]

            result = described_class.send(
                :build_records_results,
                hits,
                {
                    "test__articles__default" => [
                        first_index_target,
                        second_index_target,
                    ],
                },
                {},
            )

            expect(result).to eq(
                records: [first_record, second_record],
                records_with_hit: [
                    [
                        first_record,
                        {
                            index: "test__articles__default__2026_07_03_03_10_00_123456",
                            id: "1",
                            source: {
                                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME => [
                                    "FirstArticle",
                                ],
                            },
                            highlight: {},
                            fields: {},
                            index_target_name: :default,
                        },
                    ],
                    [
                        second_record,
                        {
                            index: "test__articles__default__2026_07_03_03_10_00_123456",
                            id: "2",
                            source: {
                                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME => [
                                    "SecondArticle",
                                ],
                            },
                            highlight: {},
                            fields: {},
                            index_target_name: :default,
                        },
                    ],
                ],
            )
        end

        it "復元したレコードとhit情報をSearchResultへ渡す" do
            record = double("article", id: 1)
            response = {
                "hits" => {
                    "total" => { "value" => 1 },
                    "hits" => [
                        {
                            "_index" => "test__articles__default__2026_07_03_03_10_00_123456",
                            "_id" => "1",
                            "_source" => {
                                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                                "title" => "Rails guide",
                            },
                            "highlight" => {
                                "title" => ["<em>Rails</em> guide"],
                            },
                            "fields" => {
                                "runtime_score" => [1.5],
                            },
                        },
                    ],
                },
            }

            expect(article_model)
                .to receive(:where)
                .with(id: ["1"])
                .and_return([record])

            result = described_class.send(
                :build_result,
                response,
                {
                    "test__articles__default" => [article_index_target],
                },
                {},
                1,
                25,
                2_000,
            )

            expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
            expect(result.records).to eq([record])
            expect(result.records_with_hit).to eq([
                [
                    record,
                    {
                        index: "test__articles__default__2026_07_03_03_10_00_123456",
                        id: "1",
                        source: {
                            AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME => ["Article"],
                            AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME => "1",
                            title: "Rails guide",
                        },
                        highlight: {
                            title: ["<em>Rails</em> guide"],
                        },
                        fields: {
                            runtime_score: [1.5],
                        },
                        index_target_name: :default,
                    },
                ],
            ])
            expect(result.raw_response).to equal(response)
        end
    end
end
