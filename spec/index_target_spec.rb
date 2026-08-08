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
            superclass:               nil,
            are_search_ar_table_name: "articles",
            are_search_index_mappings:   target_mappings,
        )
    end

    let(:index_target) do
        described_class.new(model_class, :default)
    end

    describe "同一性" do
        it "同じモデルとindex_target_nameなら同一targetとして扱う" do
            first_index_target = described_class.new(model_class, :default)
            second_index_target = described_class.new(model_class, :default)

            expect(first_index_target).to eq(second_index_target)
            expect(first_index_target.eql?(second_index_target)).to eq(true)
            expect(first_index_target.hash).to eq(second_index_target.hash)
            expect([first_index_target, second_index_target].uniq).to eq([
                first_index_target,
            ])

            records_by_index_target = {
                first_index_target => "record",
            }
            expect(records_by_index_target[second_index_target]).to eq("record")
        end

        it "index_target_nameが異なれば別targetとして扱う" do
            default_index_target = described_class.new(model_class, :default)
            archive_index_target = described_class.new(model_class, :archive)

            expect(default_index_target).not_to eq(archive_index_target)
        end

        it "model_classが異なれば別targetとして扱う" do
            other_model_class = double(
                "OtherArticle",
                name:                     "OtherArticle",
                are_search_ar_table_name: "articles",
                are_search_index_mappings:   target_mappings,
            )
            first_index_target = described_class.new(model_class, :default)
            second_index_target = described_class.new(other_model_class, :default)

            expect(first_index_target).not_to eq(second_index_target)
        end
    end

    describe "#are_search_index_alias_name" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "prefix・are_search_ar_table_name・index_target_name を区切って alias 名を作る" do
            expect(index_target.are_search_index_alias_name).to eq("test__articles__default")
        end

        it "are_search_ar_table_name と index_target_name の組み合わせが異なる index 名を区別する" do
            user_event_model = double(
                "UserEvent",
                are_search_ar_table_name: "user",
                are_search_index_mappings: { events_daily: target_mappings[:default] },
            )
            user_events_daily_model = double(
                "UserEventsDaily",
                are_search_ar_table_name: "user_events",
                are_search_index_mappings: { daily: target_mappings[:default] },
            )

            user_event_index = described_class.new(user_event_model, :events_daily)
            user_events_daily_index = described_class.new(user_events_daily_model, :daily)

            expect(user_event_index.are_search_index_alias_name).to eq("test__user__events_daily")
            expect(user_events_daily_index.are_search_index_alias_name).to eq("test__user_events__daily")
        end

    end

    describe "#are_search_index_mappings" do
        it "index_settings を除外し予約フィールドを含めない" do
            mappings = index_target.are_search_index_mappings

            expect(mappings).to eq(
                dynamic:    "strict",
                properties: {
                    id:    { type: "long" },
                    title: { type: "text" },
                },
            )
            expect(mappings[:properties]).not_to have_key(
                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME,
            )
            expect(mappings[:properties]).not_to have_key(
                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME,
            )
        end

        it "properties を元定義とは別 Hash で返す" do
            mappings = index_target.are_search_index_mappings

            expect(mappings[:properties]).not_to equal(
                target_mappings[:default][:properties],
            )

            mappings[:properties][:extra] = { type: "keyword" }

            expect(target_mappings[:default][:properties]).not_to have_key(:extra)
        end
    end

    describe "#are_search_index_mappings_for_index" do
        it "Elasticsearch に渡す mappings にだけ予約フィールド mapping を足す" do
            mappings_for_index = index_target.are_search_index_mappings_for_index

            expect(mappings_for_index[:properties]).to include(
                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME =>
                    AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAME_SETTING,
                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME =>
                    AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAME_SETTING,
            )
        end

        it "_source.includes に予約フィールドを追加する" do
            mappings_for_index = index_target.are_search_index_mappings_for_index

            expect(mappings_for_index[:_source]).to eq(
                includes: AreSearch::IndexDefinition::RESERVED_INDEX_FIELD_NAMES,
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
                mappings_for_index = index_target.are_search_index_mappings_for_index

                expect(mappings_for_index[:_source]).to eq(
                    includes: [
                        :title,
                        AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME,
                        AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME,
                    ],
                    excludes: [:body],
                )
            end

            it "予約フィールドを追加しても元の _source 定義を汚さない" do
                index_target.are_search_index_mappings_for_index

                expect(target_mappings[:default][:_source]).to eq(
                    includes: [:title],
                    excludes: [:body],
                )
            end
        end

        it "予約フィールド mapping を足しても元定義を汚さない" do
            index_target.are_search_index_mappings_for_index

            original_properties = target_mappings[:default][:properties]

            expect(original_properties).not_to have_key(
                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME,
            )
            expect(original_properties).not_to have_key(
                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME,
            )
        end

        it "予約フィールド mapping を足しても通常 mappings には混ざらない" do
            index_target.are_search_index_mappings_for_index

            mappings = index_target.are_search_index_mappings

            expect(mappings[:properties]).not_to have_key(
                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME,
            )
            expect(mappings[:properties]).not_to have_key(
                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME,
            )
        end

    end

    describe "#are_search_index_marked?" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "対象aliasのmarker存在確認をIndexMarkerへ委譲する" do
            expect(AreSearch::IndexMarker)
                .to receive(:marked?)
                .with("test__articles__default")
                .and_return(true)

            expect(index_target.are_search_index_marked?).to eq(true)
        end
    end

    describe "#are_search_index_alias_exists?" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "対象aliasの存在確認をEsAdapterへ委譲する" do
            expect(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: "test__articles__default")
                .and_return(true)

            expect(index_target.are_search_index_alias_exists?).to eq(true)
        end
    end

    describe "#are_search_clean_up" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "対象 index 名を IndexManager へ渡して処理結果を返す" do
            clean_up_result = {
                result: :success,
                message: '',
                stop_phase: nil,
                done_phases: [],
                delete_index_names: [],
            }

            expect(AreSearch::IndexManager)
                .to receive(:index_clean_up)
                .with("test__articles__default")
                .and_return(clean_up_result)

            result = index_target.are_search_clean_up

            expect(result).to equal(clean_up_result)
        end
    end

    describe "#are_search_with_index_guard" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "対象 index 名と result と operation と block を IndexManager へ渡す" do
            received_block = nil
            received_result = nil
            source_block = proc { "done" }

            expect(AreSearch::IndexManager)
                .to receive(:with_index_guard) do |index_alias_name, result, operation:, &block|
                    expect(index_alias_name).to eq("test__articles__default")
                    expect(operation).to eq("pdf_extract")
                    received_result = result
                    received_block = block

                    result[:result] = :success
                    result[:stop_phase] = nil
                end

            result = index_target.are_search_with_index_guard(
                operation: "pdf_extract",
                &source_block
            )

            expect(result).to equal(received_result)
            expect(result).to eq(
                result: :success,
                message: '',
                stop_phase: nil,
                done_phases: [],
            )
            expect(received_block).to equal(source_block)
        end
    end

    describe "#are_search_search" do
        before do
            allow(model_class)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: "test__articles__default")
                .and_return(true)
        end

        it "単一 target の relation を model_relations へ変換する" do
            relation = double("relation")

            expect(AreSearch::Searcher)
                .to receive(:search) do |index_targets, **actual_options|
                    expect(index_targets).to eq([index_target])
                    expect(actual_options).to eq(
                        queries: [
                            {
                                query_string: "Rails",
                                fields:       [:title],
                                query_type:   AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                            },
                        ],
                        model_relations: { model_class => relation },
                        page: 2,
                    )

                    :search_result
                end

            result = index_target.are_search_search(
                "Rails",
                fields:     [:title],
                query_type: AreSearch::StandardQueryBuilder::TYPE_SIMPLE_QUERY_STRING,
                relation:   relation,
                page:       2,
            )

            expect(result).to eq(:search_result)
        end

        it "relation 未指定時は model_relations を追加しない" do
            expect(AreSearch::Searcher)
                .to receive(:search) do |_index_targets, **actual_options|
                    expect(actual_options).not_to have_key(:model_relations)

                    :search_result
                end

            result = index_target.are_search_search(
                "Rails",
                fields: [:title],
            )

            expect(result).to eq(:search_result)
        end

        it "複数モデル用の model_relations は受け付けない" do
            expect do
                index_target.are_search_search(
                    "Rails",
                    fields:          [:title],
                    model_relations: { model_class => double("relation") },
                )
            end.to raise_error(ArgumentError, /未知のオプション.*model_relations/)
        end

        it "queriesは受け付けない" do
            expect do
                index_target.are_search_search(
                    "Rails",
                    fields:  [:title],
                    queries: [],
                )
            end.to raise_error(ArgumentError, /未知のオプション.*queries/)
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

                def self.are_search_index_mappings
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
                aggs: [:id],
                page: 2,
                per_page: 20,
                sort: {
                    id: :desc,
                },
                highlight: {
                    fields: [:title],
                },
            }

            shortcut_body = search_target.are_search_search(
                "Rails",
                **search_options,
                dump_body: true,
            )

            searcher_options = search_options.dup
            searcher_fields = searcher_options.delete(:fields)
            searcher_body = AreSearch::Searcher.search(
                [search_target],
                queries: [
                    {
                        query_string: "Rails",
                        fields:       searcher_fields,
                    },
                ],
                **searcher_options,
                dump_body: true,
            )

            expect(shortcut_body).to eq(searcher_body)
            expect(
                shortcut_body.dig(:query, :bool, :must, 0, :combined_fields, :fields),
            ).to eq(["title^2.0"])
        end
    end

    describe "#are_search_create_index" do
        before do
            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")
        end

        it "既存aliasがある場合は拒否する" do
            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: "test__articles__default")
                .and_return(true)

            expect(AreSearch::IndexManager)
                .not_to receive(:reindex)

            expect do
                index_target.are_search_create_index
            end.to raise_error(
                AreSearch::Error,
                "index は既に存在します: test__articles__default",
            )
        end

        it "Searchable を継承した子クラスからは拒否する" do
            searchable_parent = double("searchable_parent")
            allow(searchable_parent)
                .to receive(:include?)
                .with(AreSearch::Searchable)
                .and_return(true)

            child_model_class = double(
                "SpecialArticle",
                name:                     "SpecialArticle",
                superclass:               searchable_parent,
                are_search_ar_table_name: "articles",
                are_search_index_mappings:   target_mappings,
            )
            child_index_target = described_class.new(
                child_model_class,
                :default,
            )

            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: "test__articles__default")
                .and_return(false)

            expect(AreSearch::IndexManager)
                .not_to receive(:reindex)

            expect do
                child_index_target.are_search_create_index
            end.to raise_error(
                AreSearch::Error,
                "Searchable を継承した子クラスから create_index は実行できません: SpecialArticle",
            )
        end

        it "空index作成をcreate_index操作としてIndexManagerへ委譲する" do
            allow(AreSearch::EsAdapter)
                .to receive(:index_alias_exists?)
                .with(index_alias_name: "test__articles__default")
                .and_return(false)

            received_result = nil

            expect(AreSearch::IndexManager)
                .to receive(:reindex) do |index_alias_name, index_settings, mappings, operation, result, &block|
                    expect(index_alias_name).to eq("test__articles__default")
                    expect(index_settings).to eq(max_result_window: 2_000)
                    expect(mappings).to eq(index_target.are_search_index_mappings_for_index)
                    expect(operation).to eq("create_index")
                    expect(block.call).to eq(true)

                    received_result = result
                    result[:result] = :success
                    result[:stop_phase] = nil
                end

            result = index_target.are_search_create_index

            expect(result).to equal(received_result)
            expect(result).to eq(
                result:      :success,
                message:     '',
                failed_ids:  [],
                stop_phase:  nil,
                done_phases: [],
            )
        end
    end

    describe "#are_search_reindex" do
        let(:reindex_result) do
            {
                result: :success,
                message: '',
                failed_ids: [],
                stop_phase: nil,
                done_phases: [],
            }
        end

        it "firstならallの先頭stageでreindexする" do
            allow(model_class)
                .to receive(:are_search_get_all_sync_stage_names)
                .with(:default)
                .and_return(["default", "with_external_file"])

            expect(AreSearch::Reindexer)
                .to receive(:reindex_index_target)
                .with(index_target, "default")
                .and_return(reindex_result)

            result = index_target.are_search_reindex(stage_position: :first)

            expect(result).to equal(reindex_result)
        end

        it "lastならallの末尾stageでreindexする" do
            allow(model_class)
                .to receive(:are_search_get_all_sync_stage_names)
                .with(:default)
                .and_return(["default", "with_external_file"])

            expect(AreSearch::Reindexer)
                .to receive(:reindex_index_target)
                .with(index_target, "with_external_file")
                .and_return(reindex_result)

            result = index_target.are_search_reindex(stage_position: :last)

            expect(result).to equal(reindex_result)
        end

        it "firstとlast以外は拒否する" do
            allow(model_class)
                .to receive(:are_search_get_all_sync_stage_names)
                .with(:default)
                .and_return(["default"])

            expect(AreSearch::Reindexer)
                .not_to receive(:reindex_index_target)

            expect do
                index_target.are_search_reindex(stage_position: :middle)
            end.to raise_error(ArgumentError, /:first または :last/)
        end
    end

    describe "#are_search_delete!" do
        let(:searchable_model_class) do
            Class.new do
                def self.are_search_ar_table_name
                    "articles"
                end

                def self.are_search_index_mappings
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

            searchable_index_target.are_search_delete!(123)
        end

        it "NotFound は無視する" do
            allow(client)
                .to receive(:delete)
                .and_raise(Elastic::Transport::Transport::Errors::NotFound)

            expect do
                searchable_index_target.are_search_delete!(123)
            end.not_to raise_error
        end

        it "NotFound 以外の例外は伝播する" do
            allow(client)
                .to receive(:delete)
                .and_raise(RuntimeError, "delete failed")

            expect do
                searchable_index_target.are_search_delete!(123)
            end.to raise_error(RuntimeError, "delete failed")
        end
    end

    describe "#are_search_sync" do
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

        it "SyncRequest.are_search_find_and_try_sync に同期キーと processing_token を渡す" do
            allow(SecureRandom)
                .to receive(:uuid)
                .and_return("token-1")

            expect(AreSearch::SyncRequest)
                .to receive(:are_search_find_and_try_sync)
                .with(
                    "Article",
                    "123",
                    "test__articles__default",
                    "default",
                    "token-1",
                    reraise: true,
                )

            searchable_index_target.are_search_sync("123", "default", reraise: true)
        end
    end
end
