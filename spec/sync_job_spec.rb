# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SyncJob do
    let(:database_name)         { "app_test" }
    let(:ar_model_class_name)   { "Article" }
    let(:ar_instance_key)       { "123" }
    let(:index_alias_name)         { "test__articles__default" }
    let(:sync_stage_name)            { "default" }
    let(:processing_token)      { "token-1" }
    let(:current_database_name) { database_name }
    let(:db_config)             { double("db_config", database: current_database_name) }
    let(:article_model)         { Class.new }

    before do
        stub_const(ar_model_class_name, article_model)

        allow(article_model)
            .to receive(:connection_db_config)
            .and_return(db_config)
    end

    describe "#perform" do
        context "model class が存在しない場合" do
            it "constantize の例外を握りつぶさない" do
                expect do
                    described_class.new.perform(
                        database_name,
                        "MissingArticle",
                        ar_instance_key,
                        index_alias_name,
                        sync_stage_name,
                        processing_token,
                    )
                end.to raise_error(NameError)
            end
        end

        context "Job 作成時の database_name と worker の database_name が一致する場合" do
            let(:current_database_name) { "app_test" }

            it "SyncRequest.are_search_find_and_try_sync に processing_token と reraise: true で委譲する" do
                expect(AreSearch::SyncRequest)
                    .to receive(:are_search_find_and_try_sync)
                    .with(
                        ar_model_class_name,
                        ar_instance_key,
                        index_alias_name,
                        sync_stage_name,
                        processing_token,
                        reraise: true,
                    )

                described_class.new.perform(
                    database_name,
                    ar_model_class_name,
                    ar_instance_key,
                    index_alias_name,
                    sync_stage_name,
                    processing_token,
                )
            end
        end

        context "Job 作成時の database_name と worker の database_name が一致しない場合" do
            let(:current_database_name) { "other_test" }

            it "SyncRequest.are_search_find_and_try_sync を呼ばずに終了する" do
                expect(AreSearch::SyncRequest)
                    .not_to receive(:are_search_find_and_try_sync)

                result = described_class.new.perform(
                    database_name,
                    ar_model_class_name,
                    ar_instance_key,
                    index_alias_name,
                    sync_stage_name,
                    processing_token,
                )

                expect(result).to be_nil
            end
        end
    end
end
