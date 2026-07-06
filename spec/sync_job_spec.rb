# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SyncJob do
    let(:database_name)       { "app_test" }
    let(:ar_model_class_name) { "Article" }
    let(:target_name)         { :default }
    let(:ar_instance_key)     { "123" }
    let(:es_index_name)       { "test_articles_default" }
    let(:processing_token)    { "token-1" }
    let(:db_config)           { double("db_config", database: current_database_name) }
    let(:article_model)       { Class.new }

    before do
        stub_const(ar_model_class_name, article_model)

        allow(article_model)
            .to receive(:connection_db_config)
            .and_return(db_config)
    end

    describe "#perform" do
        context "Job 作成時の database_name と worker の database_name が一致する場合" do
            let(:current_database_name) { "app_test" }

            it "RecordSync.sync に target_name / processing_token と reraise: true で委譲する" do
                expect(AreSearch::RecordSync)
                    .to receive(:sync)
                    .with(
                        ar_model_class_name,
                        target_name,
                        ar_instance_key,
                        es_index_name,
                        processing_token,
                        reraise: true,
                    )

                described_class.new.perform(
                    database_name,
                    ar_model_class_name,
                    target_name,
                    ar_instance_key,
                    es_index_name,
                    processing_token,
                )
            end
        end

        context "Job 作成時の database_name と worker の database_name が一致しない場合" do
            let(:current_database_name) { "other_test" }

            it "RecordSync.sync を呼ばずに終了する" do
                expect(AreSearch::RecordSync)
                    .not_to receive(:sync)

                result = described_class.new.perform(
                    database_name,
                    ar_model_class_name,
                    target_name,
                    ar_instance_key,
                    es_index_name,
                    processing_token,
                )

                expect(result).to be_nil
            end
        end
    end
end
