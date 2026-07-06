# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::RecordSync, "extra cases" do
    let(:model) { class_double("Article", name: "Article") }
    let(:record) { double("record") }
    let(:logger) { double("logger") }
    let(:index_target) do
        double(
            "index_target",
            model_class:                 model,
            target_name:                 :default,
            are_search_es_index_name:    current_es_index_name,
            are_search_es_index_marked?: index_marked,
        )
    end

    let(:ar_instance_key) { "123" }
    let(:current_es_index_name) { "test_articles_default" }
    let(:request_es_index_name) { "test_articles_default" }
    let(:index_marked) { false }

    before do
        stub_const("Article", model)

        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with(request_es_index_name)
            .and_return(true)
    end

    def create_sync_request(attrs = {})
        defaults = {
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "123",
            es_index_name:       "test_articles_default",
            request_sequence:    10,
            request_sequence_at: Time.zone.now,
            retry_count:         0,
            last_error:          nil,
        }

        AreSearch::SyncRequest.create!(defaults.merge(attrs))
    end

    it "index_target_name not match では retry_count を増やさない" do
        sync_request = create_sync_request(index_target_name: "archive")

        expect(model).not_to receive(:find_by)

        result = described_class.sync_with_request(
            index_target,
            sync_request,
            "token-1",
            on_rake: true,
        )

        reloaded = AreSearch::SyncRequest.find(sync_request.id)

        expect(result).to eq(false)
        expect(reloaded.retry_count).to eq(0)
        expect(reloaded.last_error).to eq("index_target_name not match")
    end

    it "es_index_name not match では retry_count を増やさない" do
        sync_request = create_sync_request

        allow(index_target)
            .to receive(:are_search_es_index_name)
            .and_return("test_articles_v2_default")

        expect(model).not_to receive(:find_by)

        result = described_class.sync_with_request(
            index_target,
            sync_request,
            "token-1",
            on_rake: true,
        )

        reloaded = AreSearch::SyncRequest.find(sync_request.id)

        expect(result).to eq(false)
        expect(reloaded.retry_count).to eq(0)
        expect(reloaded.last_error).to eq("es_index_name not match")
    end

    describe ".try_force" do
        it "processing_token が残った sync request を強制同期し force 系カラムだけ更新する" do
            sync_request = create_sync_request(
                processing_token:    "token-1",
                processing_at:       1.hour.ago,
                force_attempt_count: 1,
            )

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            expect(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)

            result = described_class.try_force(index_target, sync_request)

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(true)
            expect(reloaded.force_attempted).to eq(true)
            expect(reloaded.force_attempted_at).not_to eq(nil)
            expect(reloaded.force_attempt_count).to eq(2)
            expect(reloaded.processing_token).to eq("token-1")
            expect(reloaded.processing_at).not_to eq(nil)
        end

        it "force 同期で例外が出た場合は retry_count を増やさず last_error を更新する" do
            sync_request = create_sync_request(
                processing_token:    "token-1",
                processing_at:       1.hour.ago,
                force_attempt_count: 0,
            )
            error = RuntimeError.new("sync failed")

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            allow(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)
                .and_raise(error)

            result = described_class.try_force(index_target, sync_request)

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.retry_count).to eq(0)
            expect(reloaded.last_error).to eq("sync failed")
            expect(reloaded.force_attempted).to eq(true)
            expect(reloaded.force_attempt_count).to eq(1)
            expect(reloaded.processing_token).to eq("token-1")
        end

        it "processing_token が無い場合は同期本体を実行しない" do
            sync_request = create_sync_request

            expect(model).not_to receive(:find_by)
            expect(record).not_to receive(:are_search_es_sync!)

            result = described_class.try_force(index_target, sync_request)

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(true)
            expect(reloaded.force_attempted).to eq(false)
            expect(reloaded.force_attempt_count).to eq(0)
        end
    end
end
