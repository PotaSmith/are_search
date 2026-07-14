# frozen_string_literal: true

require "spec_helper"

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

            def are_search_es_data(_target_name)
                { title: "hello" }
            end

            attr_accessor :id
        end
    end

    describe "include" do
        it "validation と sync 用 callback を登録する" do
            model_class = build_searchable_class

            model_class.include(described_class)

            expect(model_class.validations).to eq([:are_search_es_data_validate])
            expect(model_class.save_callbacks).to eq([:are_search_enqueue_es_sync_request])
            expect(model_class.touch_callbacks).to eq([:are_search_enqueue_es_sync_request])
            expect(model_class.destroy_callbacks).to eq([:are_search_enqueue_es_sync_request])
            expect(model_class.commit_callbacks).to eq([:are_search_after_commit])
        end
    end

    describe ".are_search_index_targets" do
        it "mappings の target_name ごとに IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            targets = model_class.are_search_index_targets

            expect(targets.size).to eq(1)
            expect(targets.first.model_class).to equal(model_class)
            expect(targets.first.target_name).to eq(:default)
            expect(targets.first.are_search_es_index_name).to eq("test_articles_default")
        end

        it "properties がトップレベルにあればエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_es_mappings)
                .and_return(
                    properties: {
                        title: { type: "text" },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /トップレベルに properties は指定できません/,
            )
        end

        it "index_settings がトップレベルにあればエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_es_mappings)
                .and_return(
                    index_settings: {
                        max_result_window: 2_000,
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /トップレベルに index_settings は指定できません/,
            )
        end

        it "target に properties が無ければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_es_mappings)
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
                .to receive(:are_search_es_mappings)
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
                .to receive(:are_search_es_mappings)
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
                .to receive(:are_search_es_mappings)
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
                .to receive(:are_search_es_mappings)
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

        it "mappings と index_settings の key が Symbol でなければエラーにする" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_es_mappings)
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
            end.to raise_error(ArgumentError, /key は Symbol/)
        end

        it "properties の script 系フィールド名は同じポリシーで拒否する" do
            script_field_names = [
                :script,
                :_script,
                :script_score,
                :map_script,
            ]

            script_field_names.each do |script_field_name|
                model_class = build_searchable_class
                model_class.include(described_class)

                allow(model_class)
                    .to receive(:are_search_es_mappings)
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
                    /script 系フィールド名は指定できません: #{script_field_name}/,
                )
            end
        end

        it "properties の通常フィールド名にscriptが途中で含まれていても許可する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(model_class)
                .to receive(:are_search_es_mappings)
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
                .to receive(:are_search_es_mappings)
                .and_return(
                    default: {
                        index_settings: {
                            max_result_window: 2_000,
                        },
                        properties: {
                            title: { type: "text" },
                            are_search_es_ar_model_class_name: { type: "keyword" },
                        },
                    },
                )

            expect do
                model_class.are_search_index_targets
            end.to raise_error(
                ArgumentError,
                /properties.*予約フィールドは指定できません: are_search_es_ar_model_class_name/,
            )
        end
    end

    describe ".are_search_index_target" do
        it "指定した target_name の IndexTarget を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            index_target = model_class.are_search_index_target("default")

            expect(index_target.target_name).to eq(:default)
            expect(index_target.model_class).to equal(model_class)
        end

        it "存在しない target_name なら nil を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            expect(model_class.are_search_index_target(:missing)).to eq(nil)
        end
    end

    describe "#are_search_es_data_validate" do
        it "validate_es_data が false なら検証しない" do
            model_class = build_searchable_class
            model_class.include(described_class)

            allow(AreSearch)
                .to receive(:validate_es_data)
                .and_return(false)

            record = model_class.new

            expect(record)
                .not_to receive(:are_search_es_data)

            expect(AreSearch::EsDataValidator)
                .not_to receive(:validate)

            record.are_search_es_data_validate
        end

        it "validate_es_data が true で data に予約フィールドがあれば validation error を追加する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            errors = double("errors")

            allow(AreSearch)
                .to receive(:validate_es_data)
                .and_return(true)

            allow(record)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_return(
                    title: "hello",
                    are_search_es_ar_instance_key: "123",
                )

            allow(record)
                .to receive(:errors)
                .and_return(errors)

            allow(AreSearch::EsDataValidator)
                .to receive(:validate)
                .and_return([])

            expect(logger)
                .to receive(:debug) do |&block|
                    expect(block.call).to include("予約フィールド")
                end

            expect(errors)
                .to receive(:add)
                .with(:base, "[Article] 検索データが不正です")

            record.are_search_es_data_validate
        end

        it "target ごとの mappings と data を EsDataValidator に渡す" do
            model_class = build_searchable_class
            model_class.include(described_class)

            mappings = { properties: { title: { type: "text" } } }
            data = { title: "hello" }
            errors = double("errors")

            allow(AreSearch)
                .to receive(:validate_es_data)
                .and_return(true)

            allow(record = model_class.new)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_return(data)

            allow(record)
                .to receive(:errors)
                .and_return(errors)

            expect(AreSearch::EsDataValidator)
                .to receive(:validate)
                .with(mappings, data)
                .and_return([])

            expect(errors)
                .not_to receive(:add)

            record.are_search_es_data_validate
        end

        it "indexable ではない target は検証しない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(record)
                .to receive(:are_search_es_indexable?)
                .with(:default)
                .and_return(false)

            expect(record)
                .not_to receive(:are_search_es_data)

            record.are_search_es_data_validate
        end

        it "不整合があれば validation error を追加する" do
            model_class = build_searchable_class
            model_class.include(described_class)

            data = { title: 123 }
            errors = double("errors")
            violations = ["title は text 型ですが String ではありません: Integer"]
            record = model_class.new
            record.id = 123

            allow(AreSearch)
                .to receive(:validate_es_data)
                .and_return(true)

            allow(record)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_return(data)

            allow(record)
                .to receive(:errors)
                .and_return(errors)

            allow(AreSearch::EsDataValidator)
                .to receive(:validate)
                .and_return(violations)

            expect(errors)
                .to receive(:add)
                .with(:base, "[Article] 検索データが不正です")

            record.are_search_es_data_validate
        end

        it "are_search_es_data の例外は握りつぶさない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:validate_es_data)
                .and_return(true)

            allow(record)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_raise(RuntimeError, "data failed")

            expect(AreSearch::EsDataValidator)
                .not_to receive(:validate)

            expect do
                record.are_search_es_data_validate
            end.to raise_error(RuntimeError, "data failed")
        end
    end

    describe "#are_search_enqueue_es_sync_request" do
        it "target ごとに SyncRequest を upsert する" do
            model_class = build_searchable_class
            stub_const("Article", model_class)
            model_class.include(described_class)
            request_sequence_at = Time.zone.now

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(AreSearch::SyncRequest)
                .to receive(:next_request_sequence)
                .and_return(42)

            allow(Time.zone)
                .to receive(:now)
                .and_return(request_sequence_at)

            record = model_class.new
            record.id = 123

            expect(AreSearch::SyncRequest)
                .to receive(:upsert)
                .with(
                    {
                        ar_model_class_name:  "Article",
                        index_target_name:    :default,
                        ar_instance_key:      "123",
                        es_index_name:        "test_articles_default",
                        request_sequence:     42,
                        request_sequence_at:  request_sequence_at,
                        retry_count:          0,
                        last_error:           nil,
                    },
                    unique_by: [:es_index_name, :ar_model_class_name, :ar_instance_key],
                )

            record.are_search_enqueue_es_sync_request
        end
    end

    describe "#are_search_enqueue_es_sync_job" do
        it "commit 後に target_name を含めて SyncJob を enqueue する" do
            model_class = build_searchable_class
            stub_const("Article", model_class)
            model_class.include(described_class)

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(SecureRandom)
                .to receive(:uuid)
                .and_return("token-1")

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)

            expect(AreSearch::SyncJob)
                .to receive(:perform_later)
                .with(
                    "app_test",
                    "Article",
                    :default,
                    "123",
                    "test_articles_default",
                    "token-1",
                )

            record.are_search_enqueue_es_sync_job(index_target)
        end
    end

    describe "#are_search_after_commit" do
        it "after_commit_mode が :job なら SyncJob を enqueue する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:job)

            expect(record)
                .to receive(:are_search_enqueue_es_sync_job)
                .with(kind_of(AreSearch::IndexTarget))

            expect(record)
                .not_to receive(:are_search_es_sync_direct)

            record.are_search_after_commit
        end

        it "after_commit_mode が :direct なら直接同期する" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:direct)

            expect(record)
                .not_to receive(:are_search_enqueue_es_sync_job)

            expect(record)
                .to receive(:are_search_es_sync_direct)
                .with(kind_of(AreSearch::IndexTarget))

            record.are_search_after_commit
        end

        it "after_commit_mode が :none なら何もしない" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new

            allow(AreSearch)
                .to receive(:after_commit_mode)
                .and_return(:none)

            expect(record)
                .not_to receive(:are_search_enqueue_es_sync_job)

            expect(record)
                .not_to receive(:are_search_es_sync_direct)

            record.are_search_after_commit
        end
    end

    describe "#are_search_es_data_for_index!" do
        it "Hash に予約フィールドを追加して同じ Hash を返す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            stub_const("SearchableArticle", model_class)

            record = model_class.new
            record.id = 123
            index_target = model_class.are_search_index_target(:default)
            data = { title: "hello" }

            allow(record)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_return(data)

            result = record.are_search_es_data_for_index!(index_target)

            expect(result).to equal(data)
            expect(result).to eq(
                title: "hello",
                AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME => "123",
                AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME => ["SearchableArticle"],
            )
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

            result = record.are_search_es_data_for_index!(index_target)

            expect(
                result[AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME],
            ).to eq([
                "SearchableGrandChild",
                "SearchableChild",
                "SearchableParent",
            ])
        end

        it "Hash 以外なら AreSearch::Error を出す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            index_target = model_class.are_search_index_target(:default)

            allow(record)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_return(nil)

            expect do
                record.are_search_es_data_for_index!(index_target)
            end.to raise_error(AreSearch::Error, /Hash を返してください/)
        end

        it "予約フィールドがあれば AreSearch::Error を出す" do
            model_class = build_searchable_class
            model_class.include(described_class)
            record = model_class.new
            index_target = model_class.are_search_index_target(:default)

            allow(record)
                .to receive(:are_search_es_data)
                .with(:default)
                .and_return(
                    title: "hello",
                    are_search_es_ar_instance_key: "123",
                )

            expect do
                record.are_search_es_data_for_index!(index_target)
            end.to raise_error(
                AreSearch::Error,
                /予約フィールドは指定できません: are_search_es_ar_instance_key/,
            )
        end
    end

    describe "#are_search_es_sync!" do
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
                .to receive(:are_search_es_data_for_index!)
                .with(index_target)
                .and_return({ title: "hello" })

            expect(client)
                .to receive(:index)
                .with(
                    index: "test_articles_default",
                    id:    "123",
                    body:  { title: "hello" },
                )

            record.are_search_es_sync!(index_target)
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
                .to receive(:are_search_es_delete!)
                .with(123)

            record.are_search_es_sync!(index_target)
        end
    end

    describe "#are_search_es_sync_direct" do
        it "RecordSync.sync に target_name と index 名と processing_token を渡す" do
            model_class = build_searchable_class
            stub_const("Article", model_class)
            model_class.include(described_class)
            index_target = model_class.are_search_index_target(:default)
            record = model_class.new
            record.id = 123

            allow(AreSearch)
                .to receive(:index_prefix)
                .and_return("test")

            allow(SecureRandom)
                .to receive(:uuid)
                .and_return("token-1")

            expect(AreSearch::RecordSync)
                .to receive(:sync)
                .with("Article", :default, "123", "test_articles_default", "token-1", reraise: false)

            record.are_search_es_sync_direct(index_target)
        end
    end
end
