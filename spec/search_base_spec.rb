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
        { max_result_window: 10_000 }
    end
    let(:document_index_settings) do
        { max_result_window: 10_000 }
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
        around do |example|
            original_index_settings = AreSearch.index_settings

            example.run
        ensure
            AreSearch.index_settings = original_index_settings
        end

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

        it "target 側に max_result_window が無ければ AreSearch.index_settings を使う" do
            AreSearch.index_settings = { max_result_window: 7_000 }

            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(refresh_interval: "1s")

            result = described_class.resolve_max_result_window([article_index_target])

            expect(result).to eq(7_000)
        end

        it "文字列キーの max_result_window も解決する" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return("max_result_window" => "6000")

            result = described_class.resolve_max_result_window([article_index_target])

            expect(result).to eq(6_000)
        end

        it "target 側と全体設定に無ければ定数を使う" do
            AreSearch.index_settings = {}

            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return({})

            result = described_class.resolve_max_result_window([article_index_target])

            expect(result).to eq(AreSearch::MAX_RESULT_WINDOW)
        end
    end

    describe ".resolve_paging_params" do
        it "from + size が max_result_window 内ならそのまま返す" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 10_000)

            result = described_class.resolve_paging_params([article_index_target], 100, 25)

            expect(result).to eq([100, 25])
        end

        it "from + size が max_result_window を超える場合は size を縮める" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 10_000)

            result = described_class.resolve_paging_params([article_index_target], 9_980, 50)

            expect(result).to eq([9_980, 20])
        end

        it "from が max_result_window と同じ場合は取得範囲を空にする" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 10_000)

            result = described_class.resolve_paging_params([article_index_target], 10_000, 50)

            expect(result).to eq([10_000, 0])
        end

        it "from が max_result_window を超える場合は from も丸める" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 10_000)

            result = described_class.resolve_paging_params([article_index_target], 12_000, 50)

            expect(result).to eq([10_000, 0])
        end

        it "複数 index target では最小の max_result_window で補正する" do
            allow(article_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 10_000)

            allow(document_index_target)
                .to receive(:are_search_es_index_settings)
                .and_return(max_result_window: 5_000)

            result = described_class.resolve_paging_params([article_index_target, document_index_target], 4_800, 500)

            expect(result).to eq([4_800, 200])
        end
    end

    describe ".validate_results_where!" do
        it "未指定なら ctx を変更しない" do
            ctx = { model_results_filters: {} }

            described_class.validate_results_where!(
                ctx,
                nil,
                [article_model],
                caller_name: :multi_search,
            )

            expect(ctx).to eq(model_results_filters: {})
        end

        it "検索対象モデルの条件だけを許可し、値は加工せず ctx に積む" do
            ctx = { model_results_filters: {} }
            filter = { status: "published" }
            opts = { article_model => filter }

            described_class.validate_results_where!(
                ctx,
                opts,
                [article_model],
                caller_name: :multi_search,
            )

            expect(ctx[:model_results_filters]).to equal(opts)
            expect(ctx[:model_results_filters][article_model]).to equal(filter)
        end

        it "検索対象外モデルが指定された場合は ArgumentError を出す" do
            ctx = { model_results_filters: {} }
            opts = { document_model => { visible: true } }

            expect do
                described_class.validate_results_where!(
                    ctx,
                    opts,
                    [article_model],
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /model_results_where/)
        end
    end

    describe ".validate_includes!" do
        it "検索対象モデルの includes だけを許可し、値は加工せず ctx に積む" do
            ctx = { model_includes: {} }
            includes = [:user, :tags]
            opts = { article_model => includes }

            described_class.validate_includes!(
                ctx,
                opts,
                [article_model],
                caller_name: :multi_search,
            )

            expect(ctx[:model_includes]).to equal(opts)
            expect(ctx[:model_includes][article_model]).to equal(includes)
        end

        it "検索対象外モデルが指定された場合は ArgumentError を出す" do
            ctx = { model_includes: {} }
            opts = { document_model => [:author] }

            expect do
                described_class.validate_includes!(
                    ctx,
                    opts,
                    [article_model],
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /model_includes/)
        end
    end
end
