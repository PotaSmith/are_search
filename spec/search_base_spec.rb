# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchBase do
    let(:article_model) do
        class_double("Article", name: "Article")
    end
    let(:document_model) do
        class_double("Document", name: "Document")
    end
    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                    article_model,
            target_name:                    :default,
            are_search_es_index_name:       "test_articles_default",
            are_search_es_mappings:         article_mappings,
            are_search_es_index_settings:   article_index_settings,
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                    document_model,
            target_name:                    :default,
            are_search_es_index_name:       "test_documents_default",
            are_search_es_mappings:         document_mappings,
            are_search_es_index_settings:   document_index_settings,
        )
    end
    let(:article_mappings) do
        {
            properties: {
                title:  { type: "text" },
                status: { type: "keyword" },
            },
        }
    end
    let(:document_mappings) do
        {
            properties: {
                name: { type: "text" },
            },
        }
    end
    let(:article_index_settings) do
        { max_result_window: 2_000 }
    end
    let(:document_index_settings) do
        { max_result_window: 2_000 }
    end

    describe ".deep_symbolize_opts" do
        it "Array 内の Hash まで再帰的に Symbol key へ統一する" do
            options = [
                {
                    "field" => "status",
                    "value" => {
                        "gte" => 1,
                    },
                },
            ]

            result = described_class.deep_symbolize_opts(options)

            expect(result).to eq([
                {
                    field: "status",
                    value: {
                        gte: 1,
                    },
                },
            ])
        end

        it "HashでもArrayでもない値は変更しない" do
            value = Object.new

            result = described_class.deep_symbolize_opts(value)

            expect(result).to equal(value)
        end
    end

    describe ".check_index_exists?" do
        it "全 index target の alias が存在すれば true を返す" do
            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_articles_default")
                .and_return(true)

            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_documents_default")
                .and_return(true)

            result = described_class.check_index_exists?([article_index_target, document_index_target])

            expect(result).to eq(true)
        end

        it "ひとつでも alias が無ければ false を返す" do
            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_articles_default")
                .and_return(true)

            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_documents_default")
                .and_return(false)

            result = described_class.check_index_exists?([article_index_target, document_index_target])

            expect(result).to eq(false)
        end
    end

    describe ".index_marked?" do
        it "対象 index targets のいずれかに marker があれば true を返す" do
            allow(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_articles_default")
                .and_return(false)

            allow(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_documents_default")
                .and_return(true)

            result = described_class.index_marked?([article_index_target, document_index_target])

            expect(result).to eq(true)
        end

        it "対象 index targets のどれにも marker が無ければ false を返す" do
            allow(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_articles_default")
                .and_return(false)

            allow(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_documents_default")
                .and_return(false)

            result = described_class.index_marked?([article_index_target, document_index_target])

            expect(result).to eq(false)
        end
    end

    describe ".index_ready?" do
        it "marker が無く全 index target の alias が存在すれば true を返す" do
            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_articles_default")
                .and_return(false)

            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_documents_default")
                .and_return(false)

            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_articles_default")
                .and_return(true)

            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_documents_default")
                .and_return(true)

            result = described_class.index_ready?([article_index_target, document_index_target])

            expect(result).to eq(true)
        end

        it "marker があれば Elasticsearch の alias 確認をせず false を返す" do
            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_articles_default")
                .and_return(true)

            expect(AreSearch::IndexManager)
                .not_to receive(:es_index_alias_exists?)

            result = described_class.index_ready?([article_index_target, document_index_target])

            expect(result).to eq(false)
        end

        it "Elasticsearch の alias 確認で例外が出たら false を返す" do
            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_articles_default")
                .and_return(false)

            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test_documents_default")
                .and_return(false)

            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test_articles_default")
                .and_raise(RuntimeError, "es down")

            result = described_class.index_ready?([article_index_target, document_index_target])

            expect(result).to eq(false)
        end
    end

    describe ".build_index_to_index_target" do
        it "alias 名だけを index_target に対応付ける" do
            expect(AreSearch::IndexManager)
                .not_to receive(:es_get_alias_physical_names)

            result = described_class.build_index_to_index_target([article_index_target, document_index_target])

            expect(result).to eq(
                "test_articles_default"  => article_index_target,
                "test_documents_default" => document_index_target,
            )
        end
    end

    describe "物理 index 名からの index_target 解決" do
        it "alias 名そのものなら対応する index_target を返す" do
            index_to_index_target = described_class.build_index_to_index_target([article_index_target])

            result = described_class.send(
                :index_target_for_hit_index,
                index_to_index_target,
                "test_articles_default",
            )

            expect(result).to equal(article_index_target)
        end

        it "AreSearch の物理 index 名なら末尾 timestamp を削って index_target を返す" do
            index_to_index_target = described_class.build_index_to_index_target([article_index_target])

            result = described_class.send(
                :index_target_for_hit_index,
                index_to_index_target,
                "test_articles_default_2026_07_03_03_10_00_123456",
            )

            expect(result).to equal(article_index_target)
        end

        it "timestamp 形式でない index 名は削らず unknown 扱いにする" do
            index_to_index_target = described_class.build_index_to_index_target([article_index_target])

            result = described_class.send(
                :index_target_for_hit_index,
                index_to_index_target,
                "test_articles_default_20260703031000",
            )

            expect(result).to eq(nil)
        end
    end

    describe ".resolve_max_result_window" do
        it "複数 index target では最小の max_result_window を返す" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 8_000)

            allow(document_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 5_000)

            result = described_class.resolve_max_result_window([article_index_target, document_index_target])

            expect(result).to eq(5_000)
        end

        it "index target の index_settings から max_result_window を読む" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 6_000, refresh_interval: "1s")

            result = described_class.resolve_max_result_window([article_index_target])

            expect(result).to eq(6_000)
        end
    end

    describe ".resolve_paging_params" do
        it "from + size が max_result_window 内ならそのまま返す" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 2_000)

            result = described_class.resolve_paging_params([article_index_target], 100, 25)

            expect(result).to eq([100, 25])
        end

        it "from + size が max_result_window を超える場合は size を縮める" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 2_000)

            result = described_class.resolve_paging_params([article_index_target], 1_980, 50)

            expect(result).to eq([1_980, 20])
        end

        it "from が max_result_window と同じ場合は取得範囲を空にする" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 2_000)

            result = described_class.resolve_paging_params([article_index_target], 2_000, 50)

            expect(result).to eq([2_000, 0])
        end

        it "from が max_result_window を超える場合は from も丸める" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 2_000)

            result = described_class.resolve_paging_params([article_index_target], 12_000, 50)

            expect(result).to eq([2_000, 0])
        end

        it "複数 index target では最小の max_result_window で補正する" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 8_000)

            allow(document_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 5_000)

            result = described_class.resolve_paging_params([article_index_target, document_index_target], 4_800, 500)

            expect(result).to eq([4_800, 200])
        end
    end

    describe ".execute_and_build_result" do
        it "highlight 未指定でも Elasticsearch の _source を hit_source として保持する" do
            record_class = Struct.new(:id)
            record = record_class.new(1)
            index_to_index_target = {
                "test_articles_default" => article_index_target,
            }
            search_body = {
                query: {
                    match_all: {},
                },
            }
            hits = [
                {
                    "_index" => "test_articles_default",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => "Article",
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                        "title" => "Rails guide",
                    },
                },
            ]
            response = {
                "hits" => {
                    "total" => {
                        "value" => 1,
                    },
                    "hits" => hits,
                },
            }
            result_context = {
                index_to_index_target: index_to_index_target,
                model_results_filters: {},
                model_includes:        {},
                page:                  1,
                per_page:              25,
            }
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            expect(client)
                .to receive(:search)
                .with(
                    index: "test_articles_default",
                    body:  search_body,
                )
                .and_return(response)

            allow(described_class)
                .to receive(:build_records)
                .with(
                    hits,
                    index_to_index_target,
                    {},
                    {},
                )
                .and_return(
                    records:                   [record],
                    records_with_target_names: [[record, :default]],
                )

            allow(article_index_target)
                .to receive(:are_search_es_composite_key) do |id|
                    "test_articles_default/#{id}"
                end

            allow(record_class)
                .to receive(:are_search_index_target)
                .with(:default)
                .and_return(article_index_target)

            result = described_class.execute_and_build_result(
                "test_articles_default",
                search_body,
                result_context,
            )

            expect(result.hit_source(record, :default)).to eq(
                AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME => "Article",
                AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME => "1",
                title: "Rails guide",
            )
            expect(result.highlights_html(record, :default)).to eq([])
        end

        it "hit_source と highlight のフラグメントを別々に保持する" do
            record_class = Struct.new(:id)
            record = record_class.new(1)
            index_to_index_target = {
                "test_articles_default" => article_index_target,
            }
            search_body = {
                query: {
                    match_all: {},
                },
                highlight: {
                    fields: {
                        title: {},
                    },
                },
            }
            hits = [
                {
                    "_index" => "test_articles_default",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => "Article",
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                        "title" => "Rails guide",
                    },
                    "highlight" => {
                        "title" => ["<em>Rails</em> guide"],
                    },
                },
            ]
            response = {
                "hits" => {
                    "total" => {
                        "value" => 1,
                    },
                    "hits" => hits,
                },
            }
            result_context = {
                index_to_index_target: index_to_index_target,
                model_results_filters: {},
                model_includes:        {},
                page:                  1,
                per_page:              25,
            }
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            expect(client)
                .to receive(:search)
                .with(
                    index: "test_articles_default",
                    body:  search_body,
                )
                .and_return(response)

            allow(described_class)
                .to receive(:build_records)
                .with(
                    hits,
                    index_to_index_target,
                    {},
                    {},
                )
                .and_return(
                    records:                   [record],
                    records_with_target_names: [[record, :default]],
                )

            allow(article_index_target)
                .to receive(:are_search_es_composite_key) do |id|
                    "test_articles_default/#{id}"
                end

            allow(record_class)
                .to receive(:are_search_index_target)
                .with(:default)
                .and_return(article_index_target)

            result = described_class.execute_and_build_result(
                "test_articles_default",
                search_body,
                result_context,
            )

            expect(result.hit_source(record, :default)[:title]).to eq("Rails guide")
            expect(result.highlights_html(record, :default)).to eq([
                "<em>Rails</em> guide",
            ])
        end

        it "String key の highlight 要求でもフラグメントを保持する" do
            record_class = Struct.new(:id)
            record = record_class.new(1)
            index_to_index_target = {
                "test_articles_default" => article_index_target,
            }
            search_body = {
                "query" => {
                    "match_all" => {},
                },
                "highlight" => {
                    "fields" => {
                        "title" => {},
                    },
                },
            }
            hits = [
                {
                    "_index" => "test_articles_default",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => "Article",
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                        "title" => "Rails guide",
                    },
                    "highlight" => {
                        "title" => ["<em>Rails</em> guide"],
                    },
                },
            ]
            response = {
                "hits" => {
                    "total" => {
                        "value" => 1,
                    },
                    "hits" => hits,
                },
            }
            result_context = {
                index_to_index_target: index_to_index_target,
                model_results_filters: {},
                model_includes:        {},
                page:                  1,
                per_page:              25,
            }
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            expect(client)
                .to receive(:search)
                .with(
                    index: "test_articles_default",
                    body:  search_body,
                )
                .and_return(response)

            allow(described_class)
                .to receive(:build_records)
                .with(
                    hits,
                    index_to_index_target,
                    {},
                    {},
                )
                .and_return(
                    records:                   [record],
                    records_with_target_names: [[record, :default]],
                )

            allow(article_index_target)
                .to receive(:are_search_es_composite_key) do |id|
                    "test_articles_default/#{id}"
                end

            allow(record_class)
                .to receive(:are_search_index_target)
                .with(:default)
                .and_return(article_index_target)

            result = described_class.execute_and_build_result(
                "test_articles_default",
                search_body,
                result_context,
            )

            expect(result.highlights_html(record, :default)).to eq([
                "<em>Rails</em> guide",
            ])
        end
    end

    describe "build_records" do
        it "予約フィールドのクラス名配列に対象モデル名を含む hit だけ復元する" do
            record = double("article", id: 1)
            index_to_index_target = {
                "test_articles_default" => article_index_target,
            }
            hits = [
                {
                    "_index" => "test_articles_default",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "SpecialArticle",
                            "Article",
                        ],
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                    },
                },
                {
                    "_index" => "test_articles_default",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "Document",
                        ],
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "2",
                    },
                },
            ]

            expect(article_model)
                .to receive(:where)
                .with(id: ["1"])
                .and_return([record])

            allow(article_index_target)
                .to receive(:are_search_es_composite_key) do |id|
                    "test_articles_default/#{id}"
                end

            result = described_class.send(
                :build_records,
                hits,
                index_to_index_target,
                {},
                {},
            )

            expect(result).to eq(
                records: [record],
                records_with_target_names: [[record, :default]],
            )
        end
    end

    describe ".validate_paging_options!" do
        it "未指定または正の整数を許可する" do
            expect do
                described_class.validate_paging_options!(
                    nil,
                    25,
                    caller_name: :multi_search,
                )
            end.not_to raise_error
        end

        it "AreSearch 内部で計算できない値を拒否する" do
            expect do
                described_class.validate_paging_options!(
                    "2",
                    25,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:page は正の整数/)

            expect do
                described_class.validate_paging_options!(
                    1,
                    0,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:per_page は正の整数/)
        end
    end

    describe ".resolve_default_option" do
        it "未指定値だけをデフォルトへ変換する" do
            expect(described_class.resolve_default_option(nil, 25)).to eq(25)
            expect(described_class.resolve_default_option(10, 25)).to eq(10)
        end
    end

    describe ".validate_results_where_options!" do
        it "未指定なら何もしない" do
            expect do
                described_class.validate_results_where_options!(
                    nil,
                    [article_model],
                    caller_name: :multi_search,
                )
            end.not_to raise_error
        end

        it "検索対象モデルの条件だけを許可し、値を変更しない" do
            filter = { status: "published" }
            opts = { article_model => filter }

            described_class.validate_results_where_options!(
                opts,
                [article_model],
                caller_name: :multi_search,
            )

            expect(opts[article_model]).to equal(filter)
        end

        it "Hash以外または検索対象外モデルを拒否する" do
            expect do
                described_class.validate_results_where_options!(
                    [],
                    [article_model],
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /model_results_where は Hash/)

            opts = { document_model => { visible: true } }

            expect do
                described_class.validate_results_where_options!(
                    opts,
                    [article_model],
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /model_results_where/)
        end
    end

    describe ".validate_includes_options!" do
        it "検索対象モデルの includes だけを許可し、値を変更しない" do
            includes = [:user, :tags]
            opts = { article_model => includes }

            described_class.validate_includes_options!(
                opts,
                [article_model],
                caller_name: :multi_search,
            )

            expect(opts[article_model]).to equal(includes)
        end

        it "Hash以外または検索対象外モデルを拒否する" do
            expect do
                described_class.validate_includes_options!(
                    [:user],
                    [article_model],
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /model_includes は Hash/)

            opts = { document_model => [:author] }

            expect do
                described_class.validate_includes_options!(
                    opts,
                    [article_model],
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /model_includes/)
        end
    end

    describe ".validate_raw_search_body!" do
        it "Hashだけを許可する" do
            expect do
                described_class.validate_raw_search_body!(
                    {
                        query: {
                            match_all: {},
                        },
                    },
                )
            end.not_to raise_error

            expect do
                described_class.validate_raw_search_body!([])
            end.to raise_error(ArgumentError, /body は Hash/)
        end
    end
end
