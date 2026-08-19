# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::Searchable do
    let(:logger) { double("logger") }

    before do
        @original_searchable_class_setting = AreSearch.searchable_class_setting

        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    after do
        AreSearch.searchable_class_setting = @original_searchable_class_setting
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

            def self.default_properties
                {
                    title: { type: "text" },
                }
            end

            def default_indexable?
                true
            end

            def default_search_data
                { title: "hello" }
            end

            attr_accessor :id
        end
    end

    def default_target_setting
        {
            settings: {
                max_result_window: 2_000,
            },
            mappings: {},
            properties_method: :default_properties,
            indexable_method: :default_indexable?,
            stages: {
                "default" => {
                    data_method: :default_search_data,
                    enqueue: true,
                    after_commit: true,
                },
            },
        }
    end

    def set_searchable_setting(
        model_class,
        class_setting = nil,
        class_name: "SearchableArticle",
        **index_target_settings
    )
        if class_setting.nil?
            class_setting = index_target_settings
        end

        stub_const(class_name, model_class)
        AreSearch.searchable_class_setting = {
            class_name => class_setting,
        }
        model_class.are_search_reset_index_targets!
    end

    def validate_searchable_setting!
        AreSearch.validate_searchable_class_setting!
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

    describe ".are_search_index_targets" do
        it "対応する設定が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)
            AreSearch.searchable_class_setting = {}

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /searchable_class_setting に "SearchableArticle" の設定がありません/,
            )
        end

        it "設定された index_target_name ごとに IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            class_setting = {
                default: default_target_setting,
                archive: default_target_setting,
            }
            set_searchable_setting(model_class, class_setting)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            targets = model_class.are_search_index_targets

            expect(targets.map(&:index_target_name)).to eq([:default, :archive])
            expect(targets.map(&:model_class)).to eq([model_class, model_class])
            expect(targets.map(&:are_search_index_alias_name)).to eq(
                [
                    "test__articles__default",
                    "test__articles__archive",
                ],
            )
        end
    end

    describe "searchable_class_setting validation" do
        it "are_search_ar_table_name が不正ならエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            model_class.define_singleton_method(:are_search_ar_table_name) { "_search_articles" }
            set_searchable_setting(model_class, default: default_target_setting)

            expect do
                validate_searchable_setting!
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
            set_searchable_setting(model_class, default: default_target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /are_search_ar_table_name/)
        end

        it "index_target_name に共通の名前規則を適用する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            set_searchable_setting(model_class, :"events-daily" => default_target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(
                ArgumentError,
                /index_target_name は、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "index_target_name に予約名を指定できない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            set_searchable_setting(
                model_class,
                are_search_reserved_ar_instance_key: default_target_setting,
            )

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /index_target_name/)
        end

        it "target に settings が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting.delete(:settings)
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /:settings がありません/)
        end

        it "target の mappings と indexable_method は省略できる" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting.delete(:mappings)
            target_setting.delete(:indexable_method)
            set_searchable_setting(model_class, default: target_setting)

            expect(validate_searchable_setting!).to eq(true)
        end

        it "mappings に nil を指定した場合はエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:mappings] = nil
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:mappings\] は Hash/)
        end

        it "indexable_method に nil を指定した場合はエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:indexable_method] = nil
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:indexable_method\] は Symbol/)
        end

        it "target に properties_method が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting.delete(:properties_method)
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /:properties_method がありません/)
        end

        it "mappings の properties 以外のトップレベルキーを許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:mappings][:dynamic] = false
            set_searchable_setting(model_class, default: target_setting)

            expect(validate_searchable_setting!).to eq(true)
        end

        it "settings が Hash でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:settings] = "invalid"
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:settings\] は Hash/)
        end

        it "settings の max_result_window が正の整数でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:settings][:max_result_window] = 0
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:max_result_window\] は正の整数/)
        end

        it "_source.enabled に false が指定されていればエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:mappings][:_source] = {
                enabled: false,
            }
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(
                ArgumentError,
                /\[:mappings\]\[:_source\]\[:enabled\] に false は指定できません/,
            )
        end

        it "_source が Hash でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:mappings][:_source] = false
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:mappings\]\[:_source\] は Hash/)
        end

        it "mappings と settings の key が Symbol でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:settings] = {
                "max_result_window" => 2_000,
            }
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /SymbolではないHash key/)
        end

        it "properties の field_name に共通の名前規則を適用する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            model_class.define_singleton_method(:default_properties) do
                {
                    :"title-value" => { type: "keyword" },
                }
            end
            set_searchable_setting(model_class, default: default_target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(
                ArgumentError,
                /field_name は、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "properties の許可されていないフィールド名は検索body policyで拒否する" do
            [:script, :script_score, :map_script].each do |script_field_name|
                model_class = build_searchable_class
                model_class.include(described_class)
                model_class.define_singleton_method(:default_properties) do
                    {
                        script_field_name => { type: "keyword" },
                    }
                end
                set_searchable_setting(model_class, default: default_target_setting)

                expect do
                    validate_searchable_setting!
                end.to raise_error(
                    ArgumentError,
                    /許可されていないfieldがあります: #{script_field_name}/,
                )
            end
        end

        it "properties の通常フィールド名にscriptが途中で含まれていても許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            model_class.define_singleton_method(:default_properties) do
                {
                    description:  { type: "text" },
                    transcript:   { type: "text" },
                    subscription: { type: "keyword" },
                }
            end
            set_searchable_setting(model_class, default: default_target_setting)

            expect(validate_searchable_setting!).to eq(true)
        end

        it "properties に予約フィールドがあればエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            model_class.define_singleton_method(:default_properties) do
                {
                    title: { type: "text" },
                    are_search_reserved_ar_model_class_name: { type: "keyword" },
                }
            end
            set_searchable_setting(model_class, default: default_target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /field_name/)
        end
    end

    describe ".are_search_index_target" do
        it "指定した index_target_name の IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            set_searchable_setting(model_class, default: default_target_setting)

            index_target = model_class.are_search_index_target("default")

            expect(index_target.index_target_name).to eq(:default)
            expect(index_target.model_class).to equal(model_class)
        end

        it "存在しない index_target_name なら nil を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            set_searchable_setting(model_class, default: default_target_setting)

            expect(model_class.are_search_index_target(:missing)).to eq(nil)
        end
    end

    describe ".are_search_index_target_alias" do
        it "指定した別名の IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:index_target_name_alias] = :main
            set_searchable_setting(model_class, default: target_setting)

            index_target = model_class.are_search_index_target_alias(:main)

            expect(index_target.index_target_name).to eq(:default)
            expect(index_target.model_class).to equal(model_class)
        end

        it "存在しない別名なら nil を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            set_searchable_setting(model_class, default: default_target_setting)

            expect(model_class.are_search_index_target_alias(:missing)).to eq(nil)
        end

        it "実 index_target_name と同じ名前を別targetのaliasに使用できる" do
            model_class = build_searchable_class
            model_class.include(described_class)

            default_setting = default_target_setting
            default_setting[:index_target_name_alias] = :archive

            archive_setting = default_target_setting
            archive_setting[:index_target_name_alias] = :default

            set_searchable_setting(
                model_class,
                default: default_setting,
                archive: archive_setting,
            )

            expect(model_class.are_search_index_target(:archive).index_target_name).to eq(:archive)
            expect(model_class.are_search_index_target_alias(:archive).index_target_name).to eq(:default)
        end

        it "別名同士は重複できない" do
            model_class = build_searchable_class
            model_class.include(described_class)

            default_setting = default_target_setting
            default_setting[:index_target_name_alias] = :main

            archive_setting = default_target_setting
            archive_setting[:index_target_name_alias] = :main

            set_searchable_setting(
                model_class,
                default: default_setting,
                archive: archive_setting,
            )

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /index_target_name_alias が重複しています/)
        end
    end

    describe "sync stage settings" do
        it "各targetにはstageを1件以上指定する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:stages] = {}
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:stages\] には1件以上のstageを定義してください/)
        end

        it "sync_stage_name に共通の名前規則を適用する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            stage_setting = target_setting[:stages].delete("default")
            target_setting[:stages]["default-stage"] = stage_setting
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(
                ArgumentError,
                /sync_stage_name は、小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください/,
            )
        end

        it "sync_stage_name に予約名を指定できない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            stage_setting = target_setting[:stages].delete("default")
            target_setting[:stages]["are_search_reserved_ar_instance_key"] = stage_setting
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /sync_stage_name/)
        end

        it "stage に data_method が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:stages]["default"].delete(:data_method)
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /:data_method がありません/)
        end

        it "enqueue は true または false だけを許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:stages]["default"][:enqueue] = :yes
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:enqueue\] は true \/ false/)
        end

        it "after_commit は true または false だけを許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:stages]["default"][:after_commit] = :yes
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(ArgumentError, /\[:after_commit\] は true \/ false/)
        end

        it "after_commit が true のstageは enqueue も true にする" do
            model_class = build_searchable_class
            model_class.include(described_class)
            target_setting = default_target_setting
            target_setting[:stages]["default"][:enqueue] = false
            set_searchable_setting(model_class, default: target_setting)

            expect do
                validate_searchable_setting!
            end.to raise_error(
                ArgumentError,
                /after_commit: true の場合 enqueue: true にしてください/,
            )
        end
    end
end

RSpec.describe AreSearch::Searchable do
    let(:logger) { double("logger") }

    before do
        @original_searchable_class_setting = AreSearch.searchable_class_setting

        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)
    end

    after do
        AreSearch.searchable_class_setting = @original_searchable_class_setting
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

            def self.default_properties
                {
                    title: { type: "text" },
                }
            end

            def default_indexable?
                true
            end

            def default_search_data
                { title: "hello" }
            end

            def with_external_file_search_data
                { title: "hello" }
            end

            attr_accessor :id
        end
    end

    def set_searchable_setting(model_class, class_name)
        AreSearch.searchable_class_setting = {
            class_name => {
                default: {
                    settings: {
                        max_result_window: 2_000,
                    },
                    mappings: {},
                    properties_method: :default_properties,
                    indexable_method: :default_indexable?,
                    stages: {
                        "default" => {
                            data_method: :default_search_data,
                            enqueue: true,
                            after_commit: true,
                        },
                        "with_external_file" => {
                            data_method: :with_external_file_search_data,
                            enqueue: false,
                            after_commit: false,
                        },
                    },
                },
            },
        }
        model_class.are_search_reset_index_targets!
    end

    describe "#are_search_index_data_for_index!" do
        it "利用側Hashを変更せず複製したHashへ予約フィールドを追加する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)
            set_searchable_setting(model_class, "SearchableArticle")

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)
            data = { title: "hello" }.freeze

            allow(index_target)
                .to receive(:are_search_index_data)
                .with(record, "default")
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
            set_searchable_setting(model_class, "SearchableArticle")

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)
            data = { title: "hello" }

            allow(index_target)
                .to receive(:are_search_index_data)
                .with(record, "default")
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
            set_searchable_setting(parent_model, "SearchableParent")

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
            stub_const("SearchableArticle", model_class)
            set_searchable_setting(model_class, "SearchableArticle")
            record = model_class.new
            index_target = model_class.are_search_index_target(:default)

            allow(index_target)
                .to receive(:are_search_index_data)
                .with(record, "with_external_file")
                .and_return(nil)

            expect do
                record.are_search_index_data_for_index!(
                    index_target,
                    "with_external_file",
                )
            end.to raise_error(
                AreSearch::Error,
                /index data は Hash を返してください: index_target=:default sync_stage="with_external_file"/,
            )
        end

        it "予約フィールドがあれば target名とstage名を含む AreSearch::Error を出す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)
            set_searchable_setting(model_class, "SearchableArticle")
            record = model_class.new
            index_target = model_class.are_search_index_target(:default)

            allow(index_target)
                .to receive(:are_search_index_data)
                .with(record, "with_external_file")
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
                /index data に予約フィールドは指定できません: index_target=:default sync_stage="with_external_file" fields=are_search_reserved_ar_instance_key/,
            )
        end
    end

    describe "#are_search_index_or_delete!" do
        it "destroyed でなければ index_target の alias に index する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)
            set_searchable_setting(model_class, "SearchableArticle")
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
                .and_return(
                    "_id"    => "123",
                    "result" => "created",
                )

            record.are_search_index_or_delete!(index_target, "default")
        end

        it "destroyed なら index_target の delete に委譲する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)
            set_searchable_setting(model_class, "SearchableArticle")
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
