# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::Searchable do
    let(:logger) { double("logger") }

    before do
        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    def build_searchable_class
        Class.new do
            def self.validations
                @validations ||= []
            end

            def self.save_callbacks
                @save_callbacks ||= []
            end

            def self.touch_callbacks
                @touch_callbacks ||= []
            end

            def self.destroy_callbacks
                @destroy_callbacks ||= []
            end

            def self.commit_callbacks
                @commit_callbacks ||= []
            end

            def self.validate(callback_name)
                validations << callback_name
            end

            def self.after_save(callback_name)
                save_callbacks << callback_name
            end

            def self.after_touch(callback_name)
                touch_callbacks << callback_name
            end

            def self.after_destroy(callback_name)
                destroy_callbacks << callback_name
            end

            def self.after_commit(callback_name)
                commit_callbacks << callback_name
            end

            def self.table_name
                "articles"
            end

            def self.connection_db_config
                Struct.new(:database).new("app_test")
            end

            def self.model_name
                Struct.new(:human).new("Article")
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

            def self.are_search_all_sync_stage_names
                {
                    default: ["default"],
                }
            end

            def are_search_index_data(_index_target_name, _sync_stage_name)
                { title: "hello" }
            end

            attr_accessor :id
        end
    end

    describe "include" do
        it "sync 用 callback だけを登録する" do
            model_class = build_searchable_class

            model_class.include(described_class)

            expect(model_class.validations).to eq([])
            expect(model_class.save_callbacks).to eq([:are_search_enqueue_sync_request])
            expect(model_class.touch_callbacks).to eq([:are_search_enqueue_sync_request])
            expect(model_class.destroy_callbacks).to eq([:are_search_enqueue_sync_request])
            expect(model_class.commit_callbacks).to eq([:are_search_after_commit])
        end
    end

    describe ".are_search_ar_table_name" do
        it "既定では Active Record の table_name を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            expect(model_class.are_search_ar_table_name).to eq("articles")
        end

        it "モデル側でオーバーライドできる" do
            model_class = build_searchable_class
            model_class.include(described_class)

            model_class.define_singleton_method(:are_search_ar_table_name) do
                "search_articles"
            end

            expect(model_class.are_search_ar_table_name).to eq("search_articles")
        end
    end

    describe ".are_search_sync_stage_names_on_enqueue" do
        it "既定では全stageを返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            expect(model_class.are_search_sync_stage_names_on_enqueue).to eq(
                default: ["default"],
            )
        end
    end

    describe ".are_search_sync_stage_names_on_after_commit" do
        it "既定では全stageを返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            expect(model_class.are_search_sync_stage_names_on_after_commit).to eq(
                default: ["default"],
            )
        end
    end

    describe ".are_search_index_targets" do
        it "are_search_ar_table_name が不正ならエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            model_class.define_singleton_method(:are_search_ar_table_name) do
                "_search_articles"
            end

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /are_search_ar_table_name は String で、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "are_search_ar_table_name に予約名を指定できない" do
            model_class = build_searchable_class
            model_class.include(described_class)

            model_class.define_singleton_method(:are_search_ar_table_name) do
                "are_search_reserved_ar_model_class_name"
            end

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /are_search_ar_table_name/)
        end

        it "mappings の index_target_name ごとに IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            targets = model_class.are_search_index_targets

            expect(targets.size).to eq(1)
            expect(targets.first.model_class).to equal(model_class)
            expect(targets.first.index_target_name).to eq(:default)
            expect(targets.first.are_search_index_alias_name).to eq("test__articles__default")
        end

        it "index_target_name に共通の名前規則を適用する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    :"events-daily" => {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /index_target_name は、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "index_target_name に予約名を指定できない" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    are_search_reserved_ar_instance_key: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /index_target_name/)
        end

        it "target に properties が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        dynamic: false,
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /:properties がありません/)
        end

        it "target に index_settings が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /:index_settings がありません/)
        end

        it "properties 以外の mappings トップレベルキーも許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        dynamic: false,
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect(model_class.are_search_index_targets.size).to eq(1)
        end

        it "index_settings が Hash でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: "invalid",
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /\[:index_settings\] は Hash/)
        end

        it "index_settings の max_result_window が正の整数でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 0,
                        },
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /\[:max_result_window\] は正の整数/)
        end

        it "_source.enabled に false が指定されていればエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        _source: {
                            enabled: false,
                        },
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /\[:_source\]\[:enabled\] に false は指定できません/,
            )
        end

        it "_source が Hash でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        _source: false,
                        properties: {
                            title: { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /\[:_source\] は Hash/)
        end

        it "mappings と index_settings の key が Symbol でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        "index_settings" => {
                            max_result_window: 2_000,
                        },
                        properties: {
                            "title" => { type: "text" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /Symbol ではない key/)
        end

        it "properties の field_name に共通の名前規則を適用する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            :"title-value" => { type: "keyword" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /field_name は、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "properties の許可されていないフィールド名は検索body policyで拒否する" do
            script_field_names = [
                :script,
                :script_score,
                :map_script,
            ]

            script_field_names.each do |script_field_name|
                model_class = build_searchable_class
                model_class.include(described_class)

                allow(model_class)
                    .to receive(:are_search_index_mappings)
                    .and_return(
                        default: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                script_field_name => { type: "keyword" },
                            },
                        },
                    )

                expect do
                    model_class.are_search_index_targets
                end.to raise_error(
                    ArgumentError,
                    /検索body policyで許可されていないフィールド名は指定できません: #{script_field_name}/,
                )
            end
        end

        it "properties の通常フィールド名にscriptが途中で含まれていても許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            description: { type: "text" },
                            transcript:  { type: "text" },
                            subscription: { type: "keyword" },
                        },
                    },
                )

            expect(model_class.are_search_index_targets.size).to eq(1)
        end

        it "properties に予約フィールドがあればエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title: { type: "text" },
                            are_search_reserved_ar_model_class_name: { type: "keyword" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /field_name/,
            )
        end
    end

    describe ".are_search_index_target" do
        it "指定した index_target_name の IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            index_target = model_class.are_search_index_target("default")

            expect(index_target.index_target_name).to eq(:default)
            expect(index_target.model_class).to equal(model_class)
        end

        it "存在しない index_target_name なら nil を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            expect(model_class.are_search_index_target(:missing)).to eq(nil)
        end
    end

    describe "sync stage settings" do
        it "allの各targetにはstageを1件以上指定する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_all_sync_stage_names)
                .and_return(default: [])

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /are_search_all_sync_stage_names\[:default\] は sync_stage_name を1件以上指定してください/,
            )
        end

        it "allの同じtarget内でsync_stage_nameを重複できない" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_all_sync_stage_names)
                .and_return(default: ["default", "default"])

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /are_search_all_sync_stage_names\[:default\] の sync_stage_name は重複できません/,
            )
        end

        it "sync_stage_name に共通の名前規則を適用する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_all_sync_stage_names)
                .and_return(default: ["default-stage"])

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /sync_stage_name は、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "sync_stage_name に予約名を指定できない" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_all_sync_stage_names)
                .and_return(default: ["are_search_reserved_ar_instance_key"])

            expect do
                model_class.are_search_index_targets
            end.to raise_error(ArgumentError, /sync_stage_name/)
        end

        it "allにはmappingsの全targetが必要" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_index_mappings)
                .and_return(
                    default: {
                        index_settings: { max_result_window: 2_000 },
                        properties: { title: { type: "text" } },
                    },
                    archive: {
                        index_settings: { max_result_window: 2_000 },
                        properties: { title: { type: "text" } },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /are_search_all_sync_stage_names は are_search_index_mappings の全targetを定義してください/,
            )
        end

        it "enqueueはallに存在するstageだけを許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_sync_stage_names_on_enqueue)
                .and_return(default: ["unknown"])

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /are_search_sync_stage_names_on_enqueue は are_search_all_sync_stage_names の部分集合にしてください/,
            )
        end

        it "after_commitはenqueueに存在するstageだけを許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_sync_stage_names_on_enqueue)
                .and_return(default: [])

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /are_search_sync_stage_names_on_after_commit は are_search_sync_stage_names_on_enqueue の部分集合にしてください/,
            )
        end
    end

end

RSpec.describe AreSearch::Searchable do
    let(:logger) { double("logger") }

    before do
        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    def build_searchable_class
        Class.new do
            def self.validations
                @validations ||= []
            end

            def self.save_callbacks
                @save_callbacks ||= []
            end

            def self.touch_callbacks
                @touch_callbacks ||= []
            end

            def self.destroy_callbacks
                @destroy_callbacks ||= []
            end

            def self.commit_callbacks
                @commit_callbacks ||= []
            end

            def self.validate(callback_name)
                validations << callback_name
            end

            def self.after_save(callback_name)
                save_callbacks << callback_name
            end

            def self.after_touch(callback_name)
                touch_callbacks << callback_name
            end

            def self.after_destroy(callback_name)
                destroy_callbacks << callback_name
            end

            def self.after_commit(callback_name)
                commit_callbacks << callback_name
            end

            def self.table_name
                "articles"
            end

            def self.connection_db_config
                Struct.new(:database).new("app_test")
            end

            def self.model_name
                Struct.new(:human).new("Article")
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

            def self.are_search_all_sync_stage_names
                {
                    default: ["default"],
                }
            end

            def are_search_index_data(_index_target_name, _sync_stage_name)
                { title: "hello" }
            end

            attr_accessor :id
        end
    end

    describe "#are_search_index_data_for_index!" do
        it "利用側Hashを変更せず複製したHashへ予約フィールドを追加する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)
            data = { title: "hello" }.freeze

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "default")
                .and_return(data)

            result = record.are_search_index_data_for_index!(index_target, "default")

            expect(result).not_to equal(data)
            expect(data).to eq(title: "hello")
            expect(result).to eq(
                title: "hello",
                AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME => "123",
                AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME => ["SearchableArticle"],
            )
        end

        it "同じ利用側Hashを複数回返しても予約フィールドで汚染しない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)
            data = { title: "hello" }

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "default")
                .and_return(data)

            first_result = record.are_search_index_data_for_index!(index_target, "default")
            second_result = record.are_search_index_data_for_index!(index_target, "default")

            expect(data).to eq(title: "hello")
            expect(first_result).not_to equal(data)
            expect(second_result).not_to equal(data)
            expect(second_result).to eq(first_result)
        end

        it "実体クラスから Searchable を実装した親クラスまでの名前を保存する" do
            parent_model = build_searchable_class
            parent_model.include(described_class)
            child_model = Class.new(parent_model)
            grand_child_model = Class.new(child_model)

            stub_const("SearchableParent", parent_model)
            stub_const("SearchableChild", child_model)
            stub_const("SearchableGrandChild", grand_child_model)

            record = grand_child_model.new
            record.id = 123
            index_target = parent_model.are_search_index_target(:default)

            result = record.are_search_index_data_for_index!(index_target, "default")

            expect(
                result[AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME],
            ).to eq([
                "SearchableGrandChild",
                "SearchableChild",
                "SearchableParent",
            ])
        end

        it "Hash 以外なら target名とstage名を含む AreSearch::Error を出す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            index_target = model_class.are_search_index_target(:default)

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "with_external_file")
                .and_return(nil)

            expect do
                record.are_search_index_data_for_index!(
                    index_target,
                    "with_external_file",
                )
            end.to raise_error(
                AreSearch::Error,
                /are_search_index_data\(:default, "with_external_file"\) は Hash を返してください/,
            )
        end

        it "予約フィールドがあれば target名とstage名を含む AreSearch::Error を出す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            index_target = model_class.are_search_index_target(:default)

            allow(record)
                .to receive(:are_search_index_data)
                .with(:default, "with_external_file")
                .and_return(
                    title: "hello",
                    are_search_reserved_ar_instance_key: "123",
                )

            expect do
                record.are_search_index_data_for_index!(
                    index_target,
                    "with_external_file",
                )
            end.to raise_error(
                AreSearch::Error,
                /are_search_index_data\(:default, "with_external_file"\) に AreSearch の予約フィールドは指定できません: are_search_reserved_ar_instance_key/,
            )
        end
    end

    describe "#are_search_index_or_delete!" do
        it "destroyed でなければ index_target の alias に index する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            client = double("client")
            index_target = model_class.are_search_index_target(:default)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(AreSearch)
                .to receive(:client)
                .and_return(client)

            record = model_class.new
            record.id = 123

            allow(record)
                .to receive(:destroyed?)
                .and_return(false)

            allow(record)
                .to receive(:are_search_index_data_for_index!)
                .with(index_target, "default")
                .and_return({ title: "hello" })

            expect(client)
                .to receive(:index)
                .with(
                    index: "test__articles__default",
                    id:    "123",
                    body:  { title: "hello" },
                )

            record.are_search_index_or_delete!(index_target, "default")
        end

        it "destroyed なら index_target の delete に委譲する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            index_target = model_class.are_search_index_target(:default)

            record = model_class.new
            record.id = 123

            allow(record)
                .to receive(:destroyed?)
                .and_return(true)

            expect(index_target)
                .to receive(:are_search_delete!)
                .with(123)

            record.are_search_index_or_delete!(index_target, "default")
        end
    end

end
