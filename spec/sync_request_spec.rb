# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AreSearch::SyncRequest do
    let(:base_attrs) do
        {
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "123",
            index_alias_name:       "test_articles",
            sync_stage_name:          "default",
            request_sequence:    10,
            request_sequence_at: Time.zone.now,
        }
    end
    let(:unique_by) do
        [
            :index_alias_name,
            :ar_model_class_name,
            :ar_instance_key,
            :sync_stage_name,
        ]
    end
    let(:base_key) do
        {
            index_alias_name:   "test_articles",
            ar_instance_key: "123",
            sync_stage_name:      "default",
        }
    end

    describe ".upsert" do
        it "実際にDBへレコードを1件登録する" do
            described_class.upsert(base_attrs, unique_by: unique_by)

            expect(described_class.count).to eq(1)

            record = described_class.find_by(base_key)
            expect(record.ar_instance_key).to eq("123")
            expect(record.index_alias_name).to eq("test_articles")
            expect(record.sync_stage_name).to eq("default")
            expect(record.request_sequence).to eq(10)
            expect(record.sync_try_count).to eq(0)
            expect(record.callback_try_count).to eq(0)
            expect(record.last_error).to eq(nil)
            expect(record.last_error_at).to eq(nil)
            expect(record.last_completed_at).to eq(nil)
        end

        it "同一同期キーで2回upsertしても重複しない" do
            described_class.upsert(base_attrs, unique_by: unique_by)
            described_class.upsert(
                base_attrs.merge(request_sequence: 11),
                unique_by: unique_by,
            )

            expect(described_class.count).to eq(1)
            expect(described_class.find_by(base_key).request_sequence).to eq(11)
        end

        it "新しい要求のupsertでは既存の処理状態とエラーを維持する" do
            described_class.upsert(base_attrs, unique_by: unique_by)

            error_at = Time.zone.now
            completed_at = error_at - 60

            described_class.find_by(base_key).update!(
                sync_try_count:   3,
                last_sync_try_at: error_at,
                callback_try_count:  2,
                last_callback_try_at: error_at,
                last_completed_at:   completed_at,
                last_error:          "connection refused",
                last_error_at:       error_at,
            )

            described_class.upsert(
                base_attrs.merge(request_sequence: 11),
                unique_by: unique_by,
            )

            record = described_class.find_by(base_key)
            expect(record.request_sequence).to eq(11)
            expect(record.sync_try_count).to eq(3)
            expect(record.last_sync_try_at).to eq(error_at)
            expect(record.callback_try_count).to eq(2)
            expect(record.last_callback_try_at).to eq(error_at)
            expect(record.last_completed_at).to eq(completed_at)
            expect(record.last_error).to eq("connection refused")
            expect(record.last_error_at).to eq(error_at)
        end

        it "stageが異なる同期要求は別々に登録する" do
            described_class.upsert(base_attrs, unique_by: unique_by)
            described_class.upsert(
                base_attrs.merge(
                    sync_stage_name:       "with_external_file",
                    request_sequence: 11,
                ),
                unique_by: unique_by,
            )

            expect(described_class.count).to eq(2)
        end

        it "レコードキーが異なる同期要求は別々に登録する" do
            described_class.upsert(base_attrs, unique_by: unique_by)
            described_class.upsert(
                base_attrs.merge(
                    ar_instance_key:  "456",
                    request_sequence: 11,
                ),
                unique_by: unique_by,
            )

            expect(described_class.count).to eq(2)
        end
    end

    describe "#update" do
        it "同期状態とエラー情報を更新できる" do
            described_class.upsert(base_attrs, unique_by: unique_by)

            error_at = Time.zone.now

            described_class.find_by(base_key).update!(
                sync_try_count: 5,
                callback_try_count: 4,
                last_error:        "timeout",
                last_error_at:     error_at,
            )

            record = described_class.find_by(base_key)
            expect(record.sync_try_count).to eq(5)
            expect(record.callback_try_count).to eq(4)
            expect(record.last_error).to eq("timeout")
            expect(record.last_error_at).to eq(error_at)
        end
    end

    describe "同期処理" do
        let(:model) { class_double("Article", name: "Article") }
        let(:record) { double("record") }
        let(:logger) { double("logger") }
        let(:index_target) do
            double(
                "index_target",
                model_class:                       model,
                index_target_name:                       :default,
                are_search_index_alias_name:          current_index_name,
                are_search_index_marked?:       index_marked,
                are_search_index_alias_exists?: index_alias_exists,
            )
        end

        let(:ar_model_class_name) { "Article" }
        let(:index_target_name) { :default }
        let(:request_index_target_name) { "default" }
        let(:ar_instance_key) { "123" }
        let(:current_index_name) { "test__articles__default" }
        let(:request_index_name) { "test__articles__default" }
        let(:sync_stage_name) { "default" }
        let(:index_marked) { false }
        let(:index_alias_exists) { true }
        let(:processing_token) { "token-1" }

        before do
            stub_const("Article", model)

            allow(logger).to receive(:debug)
            allow(Rails).to receive(:logger).and_return(logger)

            allow(model)
                .to receive(:are_search_index_target)
                .with(request_index_target_name)
                .and_return(index_target)

            allow(model)
                .to receive(:are_search_get_all_sync_stage_names)
                .with(index_target_name)
                .and_return([sync_stage_name])

            allow(model)
                .to receive(:are_search_before_sync_check)
                .and_return(true)

            allow(model)
                .to receive(:are_search_after_sync_callback)

        end

        # 各同期経路で共通に使う未完了要求を作成する。
        def create_sync_request(attrs = {})
            defaults = {
                ar_model_class_name: "Article",
                index_target_name:   "default",
                ar_instance_key:     "123",
                index_alias_name:       "test__articles__default",
                sync_stage_name:          "default",
                request_sequence:    10,
                request_sequence_at: Time.zone.now,
                sync_try_count:   0,
                callback_try_count:  0,
                last_error:          nil,
                last_error_at:       nil,
            }

            AreSearch::SyncRequest.create!(defaults.merge(attrs))
        end

        # 標準の同期キーでSyncRequest.are_search_find_and_try_syncを呼び出す。
        def sync_record(reraise: false)
            described_class.are_search_find_and_try_sync(
                ar_model_class_name,
                ar_instance_key,
                request_index_name,
                sync_stage_name,
                processing_token,
                reraise: reraise,
            )
        end

        describe ".are_search_find_and_try_sync" do
            it "stageを含む同期キーでSyncRequestを取得する" do
                create_sync_request(sync_stage_name: "with_external_file")

                expect(model).not_to receive(:find_by)

                result = sync_record

                expect(result).to eq(false)
            end

            it "index_targetが存在しない場合は同期せずエラーを残す" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:are_search_index_target)
                    .with(request_index_target_name)
                    .and_return(nil)

                expect(model).not_to receive(:find_by)

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index_target not found")
                expect(reloaded.last_error_at).not_to eq(nil)
            end

            it "index_alias_name が現在のindex_targetと違う場合は同期せずエラーを残す" do
                sync_request = create_sync_request

                allow(index_target)
                    .to receive(:are_search_index_alias_name)
                    .and_return("test__articles__v2_default")

                expect(model).not_to receive(:find_by)

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index_alias_name not match")
                expect(reloaded.processing_token).to eq(nil)
            end

            it "sync_stage_nameが現在のindex_targetに存在しない場合は同期せずエラーを残す" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:are_search_get_all_sync_stage_names)
                    .with(index_target_name)
                    .and_return(["other"])

                expect(model).not_to receive(:find_by)

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_error).to eq("sync_stage_name not found")
                expect(reloaded.last_error_at).not_to eq(nil)
                expect(reloaded.processing_token).to eq(nil)
            end

            it "index操作中の場合は同期せずindex markedを残す" do
                sync_request = create_sync_request

                allow(index_target)
                    .to receive(:are_search_index_marked?)
                    .and_return(true)

                expect(model).not_to receive(:find_by)

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index marked")
                expect(reloaded.last_error_at).not_to eq(nil)
            end

            it "indexが存在しない場合は同期せずindex not foundを残す" do
                sync_request = create_sync_request

                allow(index_target)
                    .to receive(:are_search_index_alias_exists?)
                    .and_return(false)

                expect(model).not_to receive(:find_by)

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index not found")
                expect(reloaded.last_error_at).not_to eq(nil)
            end

            it "DBにレコードがある場合はstageを渡してindexしcallback後に要求を削除する" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)

                expect(model)
                    .to receive(:are_search_after_sync_callback)
                    .with(record, index_target, sync_request)

                expect(index_target).not_to receive(:are_search_delete!)

                result = sync_record

                expect(result).to eq(true)
                expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
            end

            it "DBにレコードが無い場合はdeleteしcallback後に要求を削除する" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(nil)

                expect(index_target)
                    .to receive(:are_search_delete!)
                    .with(ar_instance_key)

                expect(model)
                    .to receive(:are_search_after_sync_callback)
                    .with(nil, index_target, sync_request)

                result = sync_record

                expect(result).to eq(true)
                expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
            end

            it "ES同期で例外が出た場合はES試行回数とエラーを更新してprocessingを解除する" do
                sync_request = create_sync_request(sync_try_count: 3)

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                allow(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)
                    .and_raise(RuntimeError, "sync failed")

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(4)
                expect(reloaded.last_sync_try_at).not_to eq(nil)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_error).to eq("sync failed")
                expect(reloaded.last_error_at).not_to eq(nil)
                expect(reloaded.processing_token).to eq(nil)
                expect(reloaded.processing_at).to eq(nil)
            end

            it "ES同期失敗前にrequest_sequenceが変わった場合も試行回数とエラーを更新する" do
                sync_request = create_sync_request(
                    request_sequence:  10,
                    sync_try_count: 3,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                allow(record)
                    .to receive(:are_search_index_or_delete!) do |actual_index_target, actual_sync_stage_name|
                        expect(actual_index_target).to eq(index_target)
                        expect(actual_sync_stage_name).to eq(sync_stage_name)

                        AreSearch::SyncRequest
                            .where(id: sync_request.id)
                            .update_all(request_sequence: 11)

                        raise RuntimeError, "sync failed"
                    end

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.request_sequence).to eq(11)
                expect(reloaded.sync_try_count).to eq(4)
                expect(reloaded.last_error).to eq("sync failed")
                expect(reloaded.last_error_at).not_to eq(nil)
                expect(reloaded.processing_token).to eq(nil)
            end

            it "callbackで例外が出た場合はESとcallbackの試行回数とエラーを更新する" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                allow(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)

                allow(model)
                    .to receive(:are_search_after_sync_callback)
                    .with(record, index_target, sync_request)
                    .and_raise(RuntimeError, "callback failed")

                result = sync_record
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(1)
                expect(reloaded.callback_try_count).to eq(1)
                expect(reloaded.last_callback_try_at).not_to eq(nil)
                expect(reloaded.last_error).to eq("callback failed")
                expect(reloaded.last_error_at).not_to eq(nil)
            end

            it "reraiseがtrueでも状態を更新して例外を再送出する" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                allow(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)
                    .and_raise(RuntimeError, "sync failed")

                expect do
                    sync_record(reraise: true)
                end.to raise_error(RuntimeError, "sync failed")

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(reloaded.sync_try_count).to eq(1)
                expect(reloaded.last_error).to eq("sync failed")
                expect(reloaded.processing_token).to eq(nil)
            end
        end

        describe "#are_search_try_sync" do
            it "processing取得中の例外は試行回数を増やさずエラーを更新する" do
                sync_request = create_sync_request(sync_try_count: 2)

                allow(sync_request)
                    .to receive(:acquire_sync_request_processing_with_sequence)
                    .with(processing_token)
                    .and_raise(RuntimeError, "processing acquire failed")

                expect(model).not_to receive(:find_by)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(2)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_error).to eq("processing acquire failed")
                expect(reloaded.last_error_at).not_to eq(nil)
            end

            it "processing_tokenが空なら同期しない" do
                sync_request = create_sync_request

                expect(model).not_to receive(:find_by)

                result = sync_request.are_search_try_sync(
                    nil,
                    on_rake: true,
                )

                expect(result).to eq(false)
                expect(AreSearch::SyncRequest.find(sync_request.id).processing_token).to eq(nil)
            end

            it "before sync checkがfalseなら同期せずprocessingを解除する" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:are_search_before_sync_check)
                    .with(ar_instance_key, index_target, sync_request)
                    .and_return(false)

                expect(model).not_to receive(:find_by)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.processing_token).to eq(nil)
                expect(reloaded.processing_at).to eq(nil)
            end

            it "別tokenで処理中の要求は取得しない" do
                sync_request = create_sync_request(
                    processing_token: "other-token",
                    processing_at:    Time.zone.now,
                )

                expect(model).not_to receive(:find_by)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(false)
                expect(reloaded.processing_token).to eq("other-token")
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.last_error).to eq(nil)
            end

            it "request_sequenceが更新済みなら処理対象にしない" do
                sync_request = create_sync_request(request_sequence: 10)
                old_sync_request = AreSearch::SyncRequest.find(sync_request.id)

                sync_request.update_columns(request_sequence: 11)

                expect(model).not_to receive(:find_by)

                result = old_sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(false)
                expect(reloaded.processing_token).to eq(nil)
            end

            it "sync試行回数更新前に要求が削除された場合は同期本体を実行せず成功扱いにする" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:are_search_before_sync_check) do
                        AreSearch::SyncRequest.where(id: sync_request.id).delete_all
                        true
                    end

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                expect(result).to eq(true)
                expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
            end

            it "callback試行回数更新前に要求が削除された場合はcallbackを実行せず成功扱いにする" do
                sync_request = create_sync_request

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!) do
                        AreSearch::SyncRequest.where(id: sync_request.id).delete_all
                    end

                expect(model).not_to receive(:are_search_after_sync_callback)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                expect(result).to eq(true)
                expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
            end

            it "rake同期中にrequest_sequenceが更新された場合は新世代要求を残して完了状態へリセットする" do
                sync_request = create_sync_request(request_sequence: 10)

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!) do
                        AreSearch::SyncRequest.where(id: sync_request.id).update_all(request_sequence: 11)
                    end

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(true)
                expect(reloaded.request_sequence).to eq(11)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_completed_at).not_to eq(nil)
                expect(reloaded.processing_token).to eq(nil)
            end

            it "job/direct同期中にrequest_sequenceが更新された場合は新世代要求を残して完了状態へリセットする" do
                sync_request = create_sync_request(request_sequence: 10)

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!) do
                        AreSearch::SyncRequest.where(id: sync_request.id).update_all(request_sequence: 11)
                    end

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: false,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(true)
                expect(reloaded.request_sequence).to eq(11)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_completed_at).not_to eq(nil)
                expect(reloaded.processing_token).to eq(nil)
            end

            it "rakeではforce_attemptedがtrueでも成功時に要求を削除する" do
                sync_request = create_sync_request(
                    force_attempted:     true,
                    last_force_try_at:  Time.zone.now,
                    force_try_count: 1,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                expect(result).to eq(true)
                expect(AreSearch::SyncRequest.find_by(id: sync_request.id)).to eq(nil)
            end

            it "job/directではforce_attemptedの要求を残し正常完了状態へリセットする" do
                sync_request = create_sync_request(
                    sync_try_count:    3,
                    callback_try_count:   2,
                    last_error:           "old error",
                    last_error_at:        Time.zone.now,
                    force_attempted:      true,
                    last_force_try_at:   Time.zone.now,
                    force_try_count:  1,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: false,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(true)
                expect(reloaded.force_attempted).to eq(true)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.last_sync_try_at).to eq(nil)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_callback_try_at).to eq(nil)
                expect(reloaded.last_completed_at).not_to eq(nil)
                expect(reloaded.last_error).to eq(nil)
                expect(reloaded.last_error_at).to eq(nil)
                expect(reloaded.processing_token).to eq(nil)
                expect(reloaded.processing_at).to eq(nil)
            end

            it "削除に失敗した場合は完了状態のリセットをロールバックしてエラーを残す" do
                sync_request = create_sync_request
                relation_call_count = 0

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)

                allow(AreSearch::SyncRequest)
                    .to receive(:where)
                    .and_call_original

                allow(AreSearch::SyncRequest)
                    .to receive(:where)
                    .with(
                        id:               sync_request.id,
                        request_sequence: sync_request.request_sequence,
                    )
                    .and_wrap_original do |original_method, *args|
                        relation_call_count += 1
                        relation = original_method.call(*args)

                        if relation_call_count == 2
                            allow(relation)
                                .to receive(:delete_all)
                                .and_raise(RuntimeError, "delete failed")
                        end

                        relation
                    end

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: true,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(1)
                expect(reloaded.callback_try_count).to eq(1)
                expect(reloaded.last_completed_at).to eq(nil)
                expect(reloaded.last_error).to eq("delete failed")
                expect(reloaded.processing_token).to eq(nil)
                expect(reloaded.processing_at).to eq(nil)
            end

            it "同期中にprocessing_tokenが変わっても終了時に解除する" do
                sync_request = create_sync_request(
                    force_attempted:     true,
                    last_force_try_at:  Time.zone.now,
                    force_try_count: 1,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!) do |actual_index_target, actual_sync_stage_name|
                        expect(actual_index_target).to eq(index_target)
                        expect(actual_sync_stage_name).to eq(sync_stage_name)

                        sync_request.update_columns(
                            processing_token: "other-token",
                            processing_at:    Time.zone.now,
                        )
                    end

                result = sync_request.are_search_try_sync(
                    processing_token,
                    on_rake: false,
                )

                reloaded = AreSearch::SyncRequest.find(sync_request.id)
                expect(result).to eq(true)
                expect(reloaded.processing_token).to eq(nil)
                expect(reloaded.processing_at).to eq(nil)
            end
        end

        describe "#are_search_try_force_sync" do
            it "index_targetが存在しない場合はforce同期せずエラーを残す" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )

                allow(model)
                    .to receive(:are_search_index_target)
                    .with(request_index_target_name)
                    .and_return(nil)

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index_target not found")
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "index_alias_nameが現在のindex_targetと違う場合はforce同期せずエラーを残す" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )

                allow(index_target)
                    .to receive(:are_search_index_alias_name)
                    .and_return("test__articles__v2_default")

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index_alias_name not match")
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "sync_stage_nameが現在のindex_targetに存在しない場合はforce同期せずエラーを残す" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                    force_try_count:  0,
                )

                allow(model)
                    .to receive(:are_search_get_all_sync_stage_names)
                    .with(index_target_name)
                    .and_return(["other"])

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_error).to eq("sync_stage_name not found")
                expect(reloaded.last_error_at).not_to eq(nil)
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "index操作中の場合はforce同期せずindex markedを残す" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )

                allow(index_target)
                    .to receive(:are_search_index_marked?)
                    .and_return(true)

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index marked")
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "indexが存在しない場合はforce同期せずindex not foundを残す" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )

                allow(index_target)
                    .to receive(:are_search_index_alias_exists?)
                    .and_return(false)

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.last_error).to eq("index not found")
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "before sync checkがfalseならforce同期せずforce試行回数を増やさない" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )

                allow(model)
                    .to receive(:are_search_before_sync_check)
                    .with(ar_instance_key, index_target, sync_request)
                    .and_return(false)

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.last_error).to eq(nil)
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "force処理開始前にprocessing_tokenが変わった場合は同期本体を実行せず成功扱いにする" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )
                stale_sync_request = AreSearch::SyncRequest.find(sync_request.id)

                sync_request.update_columns(processing_token: "other-token")

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = stale_sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(true)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
                expect(reloaded.processing_token).to eq("other-token")
            end

            it "DBにレコードが無い場合はforce同期でElasticsearchから削除する" do
                sync_request = create_sync_request(
                    processing_token: "token-1",
                    processing_at:    1.hour.ago,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(nil)

                expect(index_target)
                    .to receive(:are_search_delete!)
                    .with(ar_instance_key)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(true)
                expect(reloaded.force_attempted).to eq(true)
                expect(reloaded.force_try_count).to eq(1)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
            end

            it "processing中の要求を強制同期しforce系カラムだけ更新する" do
                sync_request = create_sync_request(
                    processing_token:    "token-1",
                    processing_at:       1.hour.ago,
                    force_try_count: 1,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                expect(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(true)
                expect(reloaded.force_attempted).to eq(true)
                expect(reloaded.last_force_try_at).not_to eq(nil)
                expect(reloaded.force_try_count).to eq(2)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "force同期で例外が出た場合は通常試行回数を増やさずエラーを更新する" do
                sync_request = create_sync_request(
                    processing_token:    "token-1",
                    processing_at:       1.hour.ago,
                    force_try_count: 0,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                allow(record)
                    .to receive(:are_search_index_or_delete!)
                    .with(index_target, sync_stage_name)
                    .and_raise(RuntimeError, "sync failed")

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.sync_try_count).to eq(0)
                expect(reloaded.callback_try_count).to eq(0)
                expect(reloaded.last_error).to eq("sync failed")
                expect(reloaded.last_error_at).not_to eq(nil)
                expect(reloaded.force_attempted).to eq(true)
                expect(reloaded.force_try_count).to eq(1)
                expect(reloaded.processing_token).to eq("token-1")
            end

            it "force同期中にrequest_sequenceが変わった場合もエラーを更新する" do
                sync_request = create_sync_request(
                    request_sequence:    10,
                    processing_token:    "token-1",
                    processing_at:       1.hour.ago,
                    force_try_count: 0,
                )

                allow(model)
                    .to receive(:find_by)
                    .with(id: ar_instance_key)
                    .and_return(record)

                allow(record)
                    .to receive(:are_search_index_or_delete!) do |actual_index_target, actual_sync_stage_name|
                        expect(actual_index_target).to eq(index_target)
                        expect(actual_sync_stage_name).to eq(sync_stage_name)

                        AreSearch::SyncRequest
                            .where(id: sync_request.id)
                            .update_all(request_sequence: 11)

                        raise RuntimeError, "sync failed"
                    end

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.request_sequence).to eq(11)
                expect(reloaded.last_error).to eq("sync failed")
                expect(reloaded.last_error_at).not_to eq(nil)
                expect(reloaded.force_attempted).to eq(true)
                expect(reloaded.force_try_count).to eq(1)
            end

            it "processing_tokenが無い場合は同期本体を実行しない" do
                sync_request = create_sync_request

                expect(model).not_to receive(:find_by)
                expect(record).not_to receive(:are_search_index_or_delete!)

                result = sync_request.are_search_try_force_sync
                reloaded = AreSearch::SyncRequest.find(sync_request.id)

                expect(result).to eq(false)
                expect(reloaded.force_attempted).to eq(false)
                expect(reloaded.force_try_count).to eq(0)
            end
        end
    end
end
