# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::RecordSync do
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

    let(:ar_model_class_name) { "Article" }
    let(:target_name) { :default }
    let(:ar_instance_key) { "123" }
    let(:current_es_index_name) { "test_articles_default" }
    let(:request_es_index_name) { "test_articles_default" }
    let(:index_marked) { false }
    let(:processing_token) { "token-1" }

    before do
        stub_const("Article", model)

        allow(logger).to receive(:debug)
        allow(Rails).to receive(:logger).and_return(logger)

        allow(model)
            .to receive(:are_search_index_target)
            .with(target_name)
            .and_return(index_target)

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

    describe ".sync" do
        it "index_target が存在しない場合は同期せず last_error を残す" do
            sync_request = create_sync_request

            allow(model)
                .to receive(:are_search_index_target)
                .with(target_name)
                .and_return(nil)

            expect(model).not_to receive(:find_by)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.retry_count).to eq(0)
            expect(reloaded.last_error).to eq("index_target not found")
        end

        it "es_index_name が現在の index_target と違う場合は同期せず last_error を残す" do
            sync_request = create_sync_request

            allow(index_target)
                .to receive(:are_search_es_index_name)
                .and_return("test_articles_v2_default")

            expect(model).not_to receive(:find_by)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.retry_count).to eq(0)
            expect(reloaded.last_error).to eq("es_index_name not match")
            expect(reloaded.processing_token).to eq(nil)
        end

        it "index 操作中の場合は同期せず last_error を index marked にする" do
            sync_request = create_sync_request

            allow(index_target)
                .to receive(:are_search_es_index_marked?)
                .and_return(true)

            expect(model).not_to receive(:find_by)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.retry_count).to eq(0)
            expect(reloaded.last_error).to eq("index marked")
            expect(reloaded.processing_token).to eq(nil)
        end

        it "index が存在しない場合は同期せず last_error を index not found にする" do
            sync_request = create_sync_request

            allow(AreSearch::IndexManager)
                .to receive(:es_index_alias_exists?)
                .with(request_es_index_name)
                .and_return(false)

            expect(model).not_to receive(:find_by)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.retry_count).to eq(0)
            expect(reloaded.last_error).to eq("index not found")
            expect(reloaded.processing_token).to eq(nil)
        end

        it "DB にレコードがある場合は index して sync request を削除する" do
            sync_request = create_sync_request

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            expect(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)

            expect(index_target).not_to receive(:are_search_es_delete!)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            expect(result).to eq(true)
            expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
        end

        it "DB にレコードが無い場合は Elasticsearch から delete して sync request を削除する" do
            sync_request = create_sync_request

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(nil)

            expect(index_target)
                .to receive(:are_search_es_delete!)
                .with(ar_instance_key)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            expect(result).to eq(true)
            expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
        end

        it "同期処理で例外が出た場合は retry_count と last_error を更新して processing を解除する" do
            sync_request = create_sync_request(retry_count: 3)
            error = RuntimeError.new("sync failed")

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            allow(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)
                .and_raise(error)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.retry_count).to eq(4)
            expect(reloaded.last_error).to eq("sync failed")
            expect(reloaded.processing_token).to eq(nil)
            expect(reloaded.processing_at).to eq(nil)
        end

        it "reraise が true の場合も retry_count と last_error を更新して processing を解除する" do
            sync_request = create_sync_request(retry_count: 3)
            error = RuntimeError.new("sync failed")

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            allow(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)
                .and_raise(error)

            expect do
                described_class.sync(
                    ar_model_class_name,
                    target_name,
                    ar_instance_key,
                    request_es_index_name,
                    processing_token,
                    reraise: true,
                )
            end.to raise_error(RuntimeError, "sync failed")

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(reloaded.retry_count).to eq(4)
            expect(reloaded.last_error).to eq("sync failed")
            expect(reloaded.processing_token).to eq(nil)
            expect(reloaded.processing_at).to eq(nil)
        end

        it "sync request が見つからない場合は false を返す" do
            expect(model).not_to receive(:find_by)

            result = described_class.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                request_es_index_name,
                processing_token,
            )

            expect(result).to eq(false)
        end
    end

    describe ".sync_with_request" do
        it "processing_token が空なら同期しない" do
            sync_request = create_sync_request

            expect(model).not_to receive(:find_by)

            result = described_class.sync_with_request(
                index_target,
                sync_request,
                nil,
                on_rake: true,
            )

            expect(result).to eq(false)
            expect(AreSearch::SyncRequest.find(sync_request.id).processing_token).to eq(nil)
        end

        it "別 token で処理中の sync request は取得しない" do
            sync_request = create_sync_request(
                processing_token: "other-token",
                processing_at:    Time.zone.now,
            )

            expect(model).not_to receive(:find_by)

            result = described_class.sync_with_request(
                index_target,
                sync_request,
                processing_token,
                on_rake: true,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.processing_token).to eq("other-token")
            expect(reloaded.retry_count).to eq(0)
            expect(reloaded.last_error).to eq(nil)
        end

        it "request_sequence が更新済みなら処理対象にしない" do
            sync_request = create_sync_request(request_sequence: 10)
            old_sync_request = AreSearch::SyncRequest.find(sync_request.id)

            sync_request.update_columns(request_sequence: 11)

            expect(model).not_to receive(:find_by)

            result = described_class.sync_with_request(
                index_target,
                old_sync_request,
                processing_token,
                on_rake: true,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(false)
            expect(reloaded.processing_token).to eq(nil)
        end

        it "rake では force_attempted が true でも成功時に sync request を削除する" do
            sync_request = create_sync_request(
                force_attempted:     true,
                force_attempted_at:  Time.zone.now,
                force_attempt_count: 1,
            )

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            expect(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)

            result = described_class.sync_with_request(
                index_target,
                sync_request,
                processing_token,
                on_rake: true,
            )

            expect(result).to eq(true)
            expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
        end

        it "job/direct では force_attempted が true の sync request を成功時に削除しない" do
            sync_request = create_sync_request(
                force_attempted:     true,
                force_attempted_at:  Time.zone.now,
                force_attempt_count: 1,
            )

            allow(model)
                .to receive(:find_by)
                .with(id: ar_instance_key)
                .and_return(record)

            expect(record)
                .to receive(:are_search_es_sync!)
                .with(index_target)

            result = described_class.sync_with_request(
                index_target,
                sync_request,
                processing_token,
                on_rake: false,
            )

            reloaded = AreSearch::SyncRequest.find(sync_request.id)

            expect(result).to eq(true)
            expect(reloaded.force_attempted).to eq(true)
            expect(reloaded.processing_token).to eq(nil)
            expect(reloaded.processing_at).to eq(nil)
        end
    end
end
