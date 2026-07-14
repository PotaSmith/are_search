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
            model_class:                  article_model,
            target_name:                  :default,
            are_search_es_index_name:     "test__articles__default",
            are_search_es_mappings:       {
                properties: {
                    title: { type: "text" },
                },
            },
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                  document_model,
            target_name:                  :default,
            are_search_es_index_name:     "test__documents__default",
            are_search_es_mappings:       {
                properties: {
                    name: { type: "text" },
                },
            },
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end

    describe ".check_index_exists?" do
        it "全 index target の alias が存在すれば true を返す" do
            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test__articles__default")
                .and_return(true)
            expect(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test__documents__default")
                .and_return(true)

            result = described_class.check_index_exists?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(true)
        end

        it "ひとつでも alias が無ければ false を返す" do
            allow(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test__articles__default")
                .and_return(true)
            allow(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test__documents__default")
                .and_return(false)

            result = described_class.check_index_exists?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(false)
        end
    end

    describe ".index_marked?" do
        it "対象 index のいずれかに marker があれば true を返す" do
            allow(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test__articles__default")
                .and_return(false)
            allow(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test__documents__default")
                .and_return(true)

            result = described_class.index_marked?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(true)
        end
    end

    describe ".index_ready?" do
        it "marker が無く全 alias が存在すれば true を返す" do
            allow(described_class)
                .to receive(:index_marked?)
                .and_return(false)
            allow(described_class)
                .to receive(:check_index_exists?)
                .and_return(true)

            result = described_class.index_ready?([
                article_index_target,
                document_index_target,
            ])

            expect(result).to eq(true)
        end

        it "marker があれば alias を確認せず false を返す" do
            expect(described_class)
                .to receive(:index_marked?)
                .and_return(true)
            expect(described_class)
                .not_to receive(:check_index_exists?)

            result = described_class.index_ready?([article_index_target])

            expect(result).to eq(false)
        end

        it "状態確認で例外が出た場合は false を返す" do
            allow(described_class)
                .to receive(:index_marked?)
                .and_raise(RuntimeError, "failed")

            result = described_class.index_ready?([article_index_target])

            expect(result).to eq(false)
        end
    end

    describe "index target 解決" do
        it "alias 名だけを index_target に対応付ける" do
            result = described_class.send(
                :build_index_to_index_target,
                [article_index_target, document_index_target],
            )

            expect(result).to eq(
                "test__articles__default"  => article_index_target,
                "test__documents__default" => document_index_target,
            )
        end

        it "物理 index 名を alias 名へ戻して index_target を返す" do
            index_to_target = described_class.send(
                :build_index_to_index_target,
                [article_index_target],
            )

            result = described_class.send(
                :index_target_for_hit_index,
                index_to_target,
                "test__articles__default__2026_07_03_03_10_00_123456",
            )

            expect(result).to equal(article_index_target)
        end

        it "timestamp 形式でない未知 index は nil を返す" do
            index_to_target = described_class.send(
                :build_index_to_index_target,
                [article_index_target],
            )

            result = described_class.send(
                :index_target_for_hit_index,
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
                    "_index" => "test__articles__default",
                    "_id" => "1",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => [
                            "SpecialArticle",
                            "Article",
                        ],
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                    },
                },
                {
                    "_index" => "test__articles__default",
                    "_id" => "2",
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
                    "test__articles__default/#{id}"
                end

            result = described_class.send(
                :build_records,
                hits,
                { "test__articles__default" => article_index_target },
                {},
                {},
            )

            expect(result).to eq(
                records: [record],
                records_with_target_names: [[record, :default]],
            )
        end

        it "highlightを要求した場合だけフラグメントを保持する" do
            record_class = Struct.new(:id)
            record = record_class.new(1)
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
                    "_index" => "test__articles__default",
                    "_id" => "1",
                    "_source" => {
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s => ["Article"],
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME.to_s => "1",
                        "title" => "Rails guide",
                    },
                    "highlight" => {
                        "title" => ["<em>Rails</em> guide"],
                    },
                },
            ]
            client = double("client")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)
            allow(client)
                .to receive(:search)
                .and_return(
                    "hits" => {
                        "total" => { "value" => 1 },
                        "hits" => hits,
                    },
                )
            allow(described_class)
                .to receive(:build_records)
                .and_return(
                    records: [record],
                    records_with_target_names: [[record, :default]],
                )
            allow(article_index_target)
                .to receive(:are_search_es_composite_key) do |id|
                    "test__articles__default/#{id}"
                end
            allow(record_class)
                .to receive(:are_search_index_target)
                .with(:default)
                .and_return(article_index_target)

            result = described_class.send(
                :execute_and_build_result,
                "test__articles__default",
                search_body,
                {
                    index_to_index_target: {
                        "test__articles__default" => article_index_target,
                    },
                    model_includes:       {},
                    model_results_wheres: {},
                    page:                 1,
                    per_page:             25,
                },
            )

            expect(result.hit_source(record, :default)[:title]).to eq("Rails guide")
            expect(result.highlights_html(record, :default)).to eq([
                "<em>Rails</em> guide",
            ])
        end
    end
end
