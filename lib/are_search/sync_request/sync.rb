# frozen_string_literal: true

module AreSearch
    class SyncRequest
        class Sync

            def initialize(sync_request)
                @sync_request = sync_request
            end

            def try_sync(processing_token, on_rake:, reraise:)
                # 同期開始条件の確認と processing の取得。
                # 条件不一致による false は同期対象外として扱い、*_count は増やさない。
                # このブロック内で例外が発生した場合は、取得したSyncRequestと同じ行が残っていれば、
                # 現在行の診断情報として last_error を更新する。
                begin
                    #index_targetを復元
                    index_target = resolve_index_target_nilable

                    # index_targetがnilの場合は、現在のモデル定義からtargetがなくなった可能性があるため、要求は消さずに残す
                    return false if check_sync_index_target?(index_target) == false
                    return false if check_sync_stage_name?(index_target) == false

                    # processing_token が無い処理は、同一 sync request の処理主体を示せないため同期しない。
                    return false if processing_token.blank?
                    return false if check_index_target_ready?(index_target) == false
                    return false if acquire_sync_request_processing_with_sequence(processing_token) != true
                rescue StandardError => e
                    update_sync_request_error_no_sequence(e.message)

                    raise e if reraise == true

                    return false
                end

                begin
                    #同期が許可されているかを確認する。
                    return false if check_index_target_sync_ready?(index_target) == false

                    # 他の sync_stage_name で sync_request が存在しないか等のチェックを行うための callback
                    return false if index_target.are_search_before_sync_check(@sync_request.ar_instance_key, @sync_request) == false

                    # 同期前のカウント更新
                    # 落ちてもなにもしない
                    return true if update_sync_try_no_sequence == false

                    # Elasticsearch への同期。
                    # 例外時は、取得したSyncRequestと同じ行が残っていれば、
                    # 現在行の診断情報として last_error を更新し、processing は ensure で解除する。
                    # processing の解除自体に失敗した場合は、この復旧処理を完了できないため例外が伝播する。
                    record = find_record_by_ar_instance_key(index_target)
                    sync_or_delete_if_record_is_nil(record, index_target)

                    # callback処理
                    # 落ちてもなにもしない
                    return true if update_callback_try_no_sequence == false
                    index_target.are_search_after_sync_callback(record, @sync_request)

                    # 同期済みの SyncRequest 削除判定と、残った行の状態リセット。
                    # 同じトランザクションにすることで、どちらかが失敗した場合は削除を確定しない。
                    # 例外時は、取得したSyncRequestと同じ行が残っていれば現在行の診断情報として
                    # last_error を更新し、processing は ensure でもう一度解除を試す。
                    AreSearch::SyncRequest.transaction do
                        if on_rake == true
                            # rake は正規の回収処理なので、ここまで到達した時点で復旧済みとして削除する。
                            sync_request_relation_with_sequence.delete_all
                        else
                            # Job / direct は、中断中に force の割り込みがあった可能性がある。
                            # force_attempted が true の行は、通常処理の成功扱いでは削除しない。
                            sync_request_relation_with_sequence.where(force_attempted: false).delete_all
                        end

                        # 成功したので、仮に更新されていていも各状態をリセット
                        reset_sync_count_no_sequence
                    end

                    return true

                rescue StandardError => e
                    update_sync_request_error_no_sequence(e.message)

                    raise e if reraise == true

                    return false
                ensure
                    release_processing_no_sequence
                end
            end

            def try_force_sync
                # 対象外
                return false if @sync_request.processing_token.blank?

                index_target = resolve_index_target_nilable

                # index_targetがnilの場合は、現在のモデル定義からtargetがなくなった可能性があるため、要求は消さずに残す
                return false if check_sync_index_target?(index_target) == false
                return false if check_sync_stage_name?(index_target) == false

                return false if check_index_target_ready?(index_target) == false

                #同期が許可されているかを確認する。
                return false if check_index_target_sync_ready?(index_target) == false

                # 他の sync_stage_name で sync_request が存在しないか等のチェックを行うための callback
                return false if index_target.are_search_before_sync_check(@sync_request.ar_instance_key, @sync_request) == false

                # force が処理したフラグ
                updated_count = sync_request_relation_no_sequence
                    .where(processing_token: @sync_request.processing_token)
                    .where.not(processing_token: nil)
                    .update_all(
                        force_attempted:   true,
                        last_force_try_at: Time.zone.now,
                        force_try_count:   Arel.sql("force_try_count + 1"),
                    )

                # ない時は、他で上手く処理した場合
                return true if updated_count != 1

                # 同期本体
                # forceはあくまで補助なので、カウント更新も、callback処理もしない
                record = find_record_by_ar_instance_key(index_target)
                sync_or_delete_if_record_is_nil(record, index_target)

                # 後処理は何もない

                true
            rescue StandardError => e
                update_sync_request_error_no_sequence(e.message)

                false
            end

            private

            # SyncRequestが保持するモデル名とtarget名から、現在のIndexTargetを解決する。
            def resolve_index_target_nilable
                model = @sync_request.ar_model_class_name.safe_constantize
                return nil if model.nil?
                return nil unless model.respond_to?(:are_search_index_target)

                model.are_search_index_target(@sync_request.index_target_name)
            end

            def find_record_by_ar_instance_key(index_target)
                index_target.model_class.unscoped.find_by(id: @sync_request.ar_instance_key)
            end

            def sync_or_delete_if_record_is_nil(record, index_target)
                if record != nil
                    record.are_search_index_or_delete!(index_target, @sync_request.sync_stage_name)
                else
                    index_target.are_search_delete!(@sync_request.ar_instance_key)
                end
            end

            #
            # SyncRequest の取り方
            #
            # 3キーで取る場合           : 更新があった場合 = 対象    他での同期成功 = 対象
            # idで取る場合              : 更新があった場合 = 対象    他での同期成功 = 対象外
            # 3キーとsequenceで取る場合 : 更新があった場合 = 対象外  他での同期成功 = 対象   構造的にありえない
            # idとsequenceで取る場合    : 更新があった場合 = 対象外  他での同期成功 = 対象外
            #

            def sync_request_relation_no_sequence
                AreSearch::SyncRequest.where(id: @sync_request.id)
            end

            def sync_request_relation_with_sequence
                AreSearch::SyncRequest.where(id: @sync_request.id, request_sequence: @sync_request.request_sequence)
            end

            # 処理中フラグを立てる
            def acquire_sync_request_processing_with_sequence(processing_token)
                updated_count = sync_request_relation_with_sequence
                    .where("processing_token IS NULL OR processing_token = ?", processing_token)
                    .update_all(
                        processing_token: processing_token,
                        processing_at:    Time.zone.now,
                    )

                updated_count == 1
            end

            def release_processing_no_sequence
                sync_request_relation_no_sequence.update_all(
                    processing_token: nil,
                    processing_at:    nil,
                )
            end

            def update_sync_try_no_sequence
                updated_count = sync_request_relation_no_sequence.update_all(
                    sync_try_count:   Arel.sql("sync_try_count + 1"),
                    last_sync_try_at: Time.zone.now,
                )

                updated_count == 1
            end

            def update_callback_try_no_sequence
                updated_count = sync_request_relation_no_sequence.update_all(
                    callback_try_count:   Arel.sql("callback_try_count + 1"),
                    last_callback_try_at: Time.zone.now,
                )

                updated_count == 1
            end

            def reset_sync_count_no_sequence
                sync_request_relation_no_sequence.update_all(
                    sync_try_count:       0,
                    last_sync_try_at:     nil,

                    callback_try_count:   0,
                    last_callback_try_at: nil,

                    last_completed_at:    Time.zone.now,

                    last_error:           nil,
                    last_error_at:        nil,
                )
            end

            # request_sequence が変わっていても、取得したSyncRequestと同じ行が残っていれば
            # 現在行の診断情報としてエラーを記録する。
            # 行が既に削除されている場合は、完了済みとして何も記録しない。
            def update_sync_request_error_no_sequence(message)
                sync_request_relation_no_sequence.update_all(last_error: message, last_error_at: Time.zone.now)
            end

            ###################################################
            # check系
            ###################################################

            # 時間差の解消のためのチェック job投入時点のmodelの情報と処理時点のmodelの情報のチェック
            def check_sync_index_target?(index_target)
                if index_target.nil?
                    AreSearch.logger.debug { "[AreSearch] sync: index targetが存在しないためスキップ #{@sync_request.ar_model_class_name} #{@sync_request.index_target_name} #{@sync_request.ar_instance_key}" }

                    update_sync_request_error_no_sequence("index_target not found")

                    return false
                end

                if index_target.are_search_index_alias_name.to_s != @sync_request.index_alias_name.to_s
                    AreSearch.logger.debug { "[AreSearch] sync: index_alias_name が 異なるためスキップ #{@sync_request.ar_model_class_name} #{@sync_request.index_alias_name}[sync_request] != #{index_target.are_search_index_alias_name}[index_target] #{@sync_request.ar_instance_key}" }

                    update_sync_request_error_no_sequence("index_alias_name not match")

                    return false
                end

                true
            end

            # SyncRequestのstageが、処理時点のIndexTargetに存在するか確認する。
            def check_sync_stage_name?(index_target)
                sync_stage_names = index_target.are_search_sync_stage_names

                return true if sync_stage_names.include?(@sync_request.sync_stage_name)

                AreSearch.logger.debug { "[AreSearch] sync: sync_stage_name が存在しないためスキップ #{@sync_request.ar_model_class_name} #{@sync_request.index_target_name} #{@sync_request.sync_stage_name} #{@sync_request.ar_instance_key}" }

                update_sync_request_error_no_sequence("sync_stage_name not found")

                false
            end

            # 時間差の解消のためのチェック job投入時点のmodelの情報と処理時点のmodelの情報のチェック
            def check_index_target_ready?(index_target)
                if index_target.are_search_index_alias_exists? == false
                    AreSearch.logger.debug { "[AreSearch] sync: index が存在しないためスキップ #{index_target.model_class.name} #{index_target.index_target_name} #{@sync_request.ar_instance_key}" }

                    update_sync_request_error_no_sequence("index not found")

                    return false
                end

                true
            end

            # 同期が許可されているかを確認
            def check_index_target_sync_ready?(index_target)
                if index_target.are_search_sync_stage_syncable?(@sync_request.sync_stage_name) == false
                    AreSearch.logger.debug { "[AreSearch] sync: sync lock 中のためスキップ #{index_target.model_class.name} #{index_target.index_target_name} #{@sync_request.ar_instance_key}" }

                    update_sync_request_error_no_sequence("sync locked")

                    return false
                end

                true
            end
        end
    end
end
