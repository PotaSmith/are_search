# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::IndexTarget do
    let(:target_mappings) do
        {
            default: {
                index_settings: {
                    max_result_window: 2_000,
                },
                dynamic:    "strict",
                properties: {
                    id:    { type: "long" },
                    title: { type: "text" },
                },
            },
        }
    end

    let(:model_class) do
        double(
            "Article",
            name:                     "Article",
            are_search_ar_table_name: "articles",
            are_search_es_mappings:   target_mappings,
        )
    end

    let(:index_target) do
        described_class.new(model_class, :default)
    end

    describe ".new" do
        it "target_name に index 名の区切り文字は使用できない" do
            expect do
                described_class.new(model_class, :"events__daily")
            end.to raise_error(ArgumentError, /target name.*"__" は使用できません/)
        end
    end

    describe "#are_search_es_index_name" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "prefix・are_search_ar_table_name・target_name を区切って alias 名を作る" do
            expect(index_target.are_search_es_index_name).to eq("test__articles__default")
        end

        it "are_search_ar_table_name と target_name の組み合わせが異なる index 名を区別する" do
            user_event_model = double(
                "UserEvent",
                are_search_ar_table_name: "user",
                are_search_es_mappings: { events_daily: target_mappings[:default] },
            )
            user_events_daily_model = double(
                "UserEventsDaily",
                are_search_ar_table_name: "user_events",
                are_search_es_mappings: { daily: target_mappings[:default] },
            )

            user_event_index = described_class.new(user_event_model, :events_daily)
            user_events_daily_index = described_class.new(user_events_daily_model, :daily)

            expect(user_event_index.are_search_es_index_name).to eq("test__user__events_daily")
            expect(user_events_daily_index.are_search_es_index_name).to eq("test__user_events__daily")
        end

        it "are_search_ar_table_name に index 名の区切り文字は使用できない" do
            delimiter_table_model = double(
                "DelimiterTable",
                are_search_ar_table_name: "user__events",
                are_search_es_mappings: { daily: target_mappings[:default] },
            )

            expect do
                described_class.new(delimiter_table_model, :daily)
            end.to raise_error(
                ArgumentError,
                /are_search_ar_table_name.*"__" は使用できません/,
            )
        end
    end

    describe "#are_search_es_mappings" do
        it "index_settings を除外し予約フィールドを含めない" do
            mappings = index_target.are_search_es_mappings

            expect(mappings).to eq(
                dynamic:    "strict",
                properties: {
                    id:    { type: "long" },
                    title: { type: "text" },
                },
            )
            expect(mappings[:properties]).not_to have_key(
                AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME,
            )
            expect(mappings[:properties]).not_to have_key(
                AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME,
            )
        end

        it "properties を元定義とは別 Hash で返す" do
            mappings = index_target.are_search_es_mappings

            expect(mappings[:properties]).not_to equal(
                target_mappings[:default][:properties],
            )

            mappings[:properties][:extra] = { type: "keyword" }

            expect(target_mappings[:default][:properties]).not_to have_key(:extra)
        end
    end

    describe "#are_search_es_mappings_for_index" do
        it "Elasticsearch に渡す mappings にだけ予約フィールド mapping を足す" do
            mappings_for_index = index_target.are_search_es_mappings_for_index

            expect(mappings_for_index[:properties]).to include(
                AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME =>
                    AreSearch::RESERVED_ES_FIELD_NAME_SETTING,
                AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME =>
                    AreSearch::RESERVED_ES_FIELD_NAME_SETTING,
            )
        end

        it "_source.includes に予約フィールドを追加する" do
            mappings_for_index = index_target.are_search_es_mappings_for_index

            expect(mappings_for_index[:_source]).to eq(
                includes: AreSearch::RESERVED_ES_FIELD_NAMES,
            )
        end

        context "利用側が _source を指定している場合" do
            let(:target_mappings) do
                {
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        _source: {
                            includes: [:title],
                            excludes: [:body],
                        },
                        properties: {
                            id:    { type: "long" },
                            title: { type: "text" },
                            body:  { type: "text" },
                        },
                    },
                }
            end

            it "既存 includes と excludes を維持して予約フィールドを追加する" do
                mappings_for_index = index_target.are_search_es_mappings_for_index

                expect(mappings_for_index[:_source]).to eq(
                    includes: [
                        :title,
                        AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME,
                        AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME,
                    ],
                    excludes: [:body],
                )
            end

            it "予約フィールドを追加しても元の _source 定義を汚さない" do
                index_target.are_search_es_mappings_for_index

                expect(target_mappings[:default][:_source]).to eq(
                    includes: [:title],
                    excludes: [:body],
                )
            end
        end

        it "予約フィールド mapping を足しても元定義を汚さない" do
            index_target.are_search_es_mappings_for_index

            original_properties = target_mappings[:default][:properties]

            expect(original_properties).not_to have_key(
                AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME,
            )
            expect(original_properties).not_to have_key(
                AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME,
            )
        end

        it "予約フィールド mapping を足しても通常 mappings には混ざらない" do
            index_target.are_search_es_mappings_for_index

            mappings = index_target.are_search_es_mappings

            expect(mappings[:properties]).not_to have_key(
                AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME,
            )
            expect(mappings[:properties]).not_to have_key(
                AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME,
            )
        end

        context "properties が無い mappings" do
            let(:target_mappings) do
                {
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        dynamic: "strict",
                    },
                }
            end

            it "予約フィールド mapping を足さずそのまま返す" do
                mappings_for_index = index_target.are_search_es_mappings_for_index

                expect(mappings_for_index).to eq(
                    dynamic: "strict",
                )
            end
        end
    end

    describe "#are_search_es_with_index_guard" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "対象 index 名と operation と block を IndexManager へ渡す" do
            received_block = nil
            source_block = proc { "done" }

            expect(AreSearch::IndexManager)
                .to receive(:es_with_index_guard) do |es_index_name, operation:, &block|
                    expect(es_index_name).to eq("test__articles__default")
                    expect(operation).to eq("pdf_extract")
                    received_block = block

                    "guard result"
                end

            result = index_target.are_search_es_with_index_guard(
                operation: "pdf_extract",
                &source_block
            )

            expect(result).to eq("guard result")
            expect(received_block).to equal(source_block)
        end
    end

    describe "#are_search_es_search" do
        before do
            allow(model_class)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with("test__articles__default")
                .and_return(true)
        end

        it "単一 target の relation を model_relations へ変換する" do
            relation = double("relation")

            expect(AreSearch::Searcher)
                .to receive(:search) do |index_targets, **actual_options|
                    expect(index_targets).to eq([index_target])
                    expect(actual_options).to eq(
                        query_string:    "Rails",
                        fields:          [:title],
                        model_relations: { model_class => relation },
                    )

                    :search_result
                end

            result = index_target.are_search_es_search(
                "Rails",
                fields:   [:title],
                relation: relation,
            )

            expect(result).to eq(:search_result)
        end

        it "relation 未指定時は model_relations を追加しない" do
            expect(AreSearch::Searcher)
                .to receive(:search) do |_index_targets, **actual_options|
                    expect(actual_options).not_to have_key(:model_relations)

                    :search_result
                end

            result = index_target.are_search_es_search(
                "Rails",
                fields: [:title],
            )

            expect(result).to eq(:search_result)
        end

        it "複数モデル用の model_relations は受け付けない" do
            expect do
                index_target.are_search_es_search(
                    "Rails",
                    fields:          [:title],
                    model_relations: { model_class => double("relation") },
                )
            end.to raise_error(ArgumentError, /未知のオプション.*model_relations/)
        end

        it "ショートハンドとSearcherが現行オプション定義から同じbodyを作る" do
            search_model = Class.new do
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

                def self.are_search_es_mappings
                    {
                        default: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                id:    { type: "long" },
                                title: { type: "text" },
                            },
                        },
                    }
                end
            end
            search_target = AreSearch::IndexTarget.new(search_model, :default)
            search_options = {
                fields: {
                    title: 2.0,
                },
                where: {
                    id: {
                        term: 1,
                    },
                },
                where_not: {
                    id: {
                        term: 2,
                    },
                },
                where_or: {
                    id: {
                        terms: [3, 4],
                    },
                },
                aggs: {
                    id: {
                        size: 20,
                    },
                },
                page: 2,
                per_page: 20,
                sort: {
                    id: :desc,
                },
                highlight: {
                    fields: [:title],
                },
            }

            shortcut_body = search_target.are_search_es_search(
                "Rails",
                **search_options,
                dump_body: true,
            )

            searcher_body = AreSearch::Searcher.search(
                [search_target],
                query_string: "Rails",
                **search_options,
                dump_body: true,
            )

            expect(shortcut_body).to eq(searcher_body)
            expect(
                shortcut_body.dig(:query, :bool, :must, :combined_fields, :fields),
            ).to eq(["title^2.0"])
        end
    end

    describe "#are_search_es_delete!" do
        let(:searchable_model_class) do
            Class.new do
                def self.are_search_ar_table_name
                    "articles"
                end

                def self.are_search_es_mappings
                    {
                        default: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                title: { type: "text" },
                            },
                        },
                    }
                end
            end
        end

        let(:searchable_index_target) do
            described_class.new(searchable_model_class, :default)
        end

        let(:client) do
            double("client")
        end

        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
            allow(AreSearch)
                .to receive(:client)
                .and_return(client)
        end

        it "指定した id を alias から delete する" do
            expect(client)
                .to receive(:delete)
                .with(index: "test__articles__default", id: "123")
                .and_return("result" => "deleted")

            result = searchable_index_target.are_search_es_delete!(123)

            expect(result).to eq("result" => "deleted")
        end

        it "NotFound は無視する" do
            allow(client)
                .to receive(:delete)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            expect do
                searchable_index_target.are_search_es_delete!(123)
            end.not_to raise_error
        end

        it "NotFound 以外の例外は伝播する" do
            allow(client)
                .to receive(:delete)
                .and_raise(RuntimeError, "delete failed")

            expect do
                searchable_index_target.are_search_es_delete!(123)
            end.to raise_error(RuntimeError, "delete failed")
        end
    end

    describe "#are_search_es_sync" do
        let(:searchable_model_class) do
            Class.new do
                def self.are_search_ar_table_name
                    "articles"
                end
            end
        end

        let(:searchable_index_target) do
            described_class.new(searchable_model_class, :default)
        end

        before do
            stub_const("Article", searchable_model_class)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "RecordSync.sync に target_name と index 名と processing_token を渡す" do
            allow(SecureRandom)
                .to receive(:uuid)
                .and_return("token-1")

            expect(AreSearch::RecordSync)
                .to receive(:sync)
                .with(
                    "Article",
                    :default,
                    "123",
                    "test__articles__default",
                    "token-1",
                    reraise: true,
                )

            searchable_index_target.are_search_es_sync("123", reraise: true)
        end
    end
end
