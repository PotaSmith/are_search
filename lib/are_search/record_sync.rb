# frozen_string_literal: true

module AreSearch
    module RecordSync
        extend self

        def sync(ar_model_class_name, target_name, ar_instance_key, es_index_name, processing_token, reraise: false)

            # sync処理時点の、おそらく自分の処理対象であろうと思われる SyncRequest を取得する。
            # Job の場合は投入時点から時間差があるため、現在の SyncRequest を取り直す。
            sync_request = find_sync_request(ar_model_class_name, ar_instance_key, es_index_name)
            return false if sync_request.nil?

            model = ar_model_class_name.safe_constantize

            if model != nil && model.respond_to?(:are_search_index_target)
                index_target = model.are_search_index_target(target_name)
            else
                # nilにしてしまって、次でエラーを出させる
                index_target = nil
            end

            sync_with_request(index_target, sync_request, processing_token, on_rake: false, reraise: reraise)
        end

        def sync_with_request(index_target, sync_request, processing_token, on_rake: true, reraise: false)
            # 同期開始条件の確認と processing の取得。
            # 条件不一致による false は同期対象外として扱い、retry_count は増やさない。
            # このブロック内で例外が発生した場合だけ、request_sequence が一致する行の
            # retry_count と last_error を更新する。
            begin
                # index_targetがnilの場合は、target_nameがなくなった場合が考えられるが、安易に消すわけにも行かない
                return false unless check_index_target?(index_target, sync_request)

                # processing_token が無い処理は、同一 sync request の処理主体を示せないため同期しない。
                return false if processing_token.blank?
                return false unless ready_to_sync?(index_target, sync_request)
                return false unless acquire_sync_request_processing(sync_request, processing_token)
            rescue StandardError => e
                update_sync_request_error(sync_request, e)

                raise e if reraise

                return false
            end

            begin
                # Elasticsearch への同期。
                # 例外時は processing を解除してから、request_sequence が一致する行の
                # retry_count と last_error を更新する。
                # processing の解除自体に失敗した場合は、この復旧処理を完了できないため例外が伝播する。
                es_sync(index_target, sync_request)

                # 同期済みの SyncRequest 削除と processing 解除。
                # 同じトランザクションにすることで、どちらかが失敗した場合は削除を確定しない。
                # 例外時はトランザクション外でもう一度 processing の解除を試し、
                # request_sequence が一致する行の retry_count と last_error を更新する。
                AreSearch::SyncRequest.transaction do
                    if on_rake
                        # rake は正規の回収処理なので、ここまで到達した時点で復旧済みとして削除する。
                        AreSearch::SyncRequest.where(
                            id:               sync_request.id,
                            request_sequence: sync_request.request_sequence,
                        ).delete_all
                    else
                        # Job / direct は、中断中に force の割り込みがあった可能性がある。
                        # force_attempted が true の行は、通常処理の成功扱いでは削除しない。
                        AreSearch::SyncRequest.where(
                            id:               sync_request.id,
                            request_sequence: sync_request.request_sequence,
                        ).where(
                            force_attempted: false,
                        ).delete_all
                    end

                    release_current_processing(sync_request)
                end

                return true

            rescue StandardError => e
                release_current_processing(sync_request)
                update_sync_request_error(sync_request, e)

                raise e if reraise

                return false
            end
        end

        def try_force(index_target, sync_request)
            # index_targetがnilの場合は、target_nameがなくなった場合が考えられるが、安易に消すわけにも行かない
            return false unless check_index_target?(index_target, sync_request)

            return false unless ready_to_sync?(index_target, sync_request)

            # force が処理したフラグ
            updated_count = AreSearch::SyncRequest
                .where(id: sync_request.id, processing_token: sync_request.processing_token)
                .where.not(processing_token: nil)
                .update_all(
                    force_attempted:     true,
                    force_attempted_at:  Time.zone.now,
                    force_attempt_count: Arel.sql("force_attempt_count + 1"),
                )

            # ない時は、他で上手く処理した場合
            return true unless updated_count == 1

            # 同期本体
            es_sync(index_target, sync_request)

            # 後処理は何もない

            true
        rescue StandardError => e
            update_force_attempt_request_error(sync_request, e)

            false
        end

        private

        def es_sync(index_target, sync_request)
            record = index_target.model_class.find_by(id: sync_request.ar_instance_key)

            if record
                record.are_search_es_sync!(index_target)
            else
                index_target.are_search_es_delete!(sync_request.ar_instance_key)
            end
        end

        def find_sync_request(ar_model_class_name, ar_instance_key, es_index_name)
            AreSearch::SyncRequest.find_by(
                ar_model_class_name: ar_model_class_name,
                ar_instance_key:     ar_instance_key.to_s,
                es_index_name:       es_index_name,
            )
        end

        def current_sync_request_relation(sync_request)
            AreSearch::SyncRequest.where(
                id:               sync_request.id,
                request_sequence: sync_request.request_sequence,
            )
        end

        # 時間差の解消のためのチェック job投入時点のmodelの情報と処理時点のmodelの情報のチェック
        def check_index_target?(index_target, sync_request)
            if index_target.nil?
                AreSearch.logger.debug { "[AreSearch] sync: index targetが存在しないためスキップ #{sync_request.ar_model_class_name} #{sync_request.index_target_name} #{sync_request.ar_instance_key}" }

                update_sync_request_last_error(sync_request, "index_target not found")

                return false
            end

            if index_target.target_name.to_s != sync_request.index_target_name.to_s
                AreSearch.logger.debug { "[AreSearch] sync: index_target_name が 異なるためスキップ #{sync_request.ar_model_class_name} #{sync_request.index_target_name}[sync_request] != #{index_target.target_name}[index_target] #{sync_request.ar_instance_key}" }

                update_sync_request_last_error(sync_request, "index_target_name not match")

                return false
            end

            if index_target.are_search_es_index_name.to_s != sync_request.es_index_name.to_s
                AreSearch.logger.debug { "[AreSearch] sync: es_index_name が 異なるためスキップ #{sync_request.ar_model_class_name} #{sync_request.es_index_name}[sync_request] != #{index_target.are_search_es_index_name}[index_target] #{sync_request.ar_instance_key}" }

                update_sync_request_last_error(sync_request, "es_index_name not match")

                return false
            end

            true
        end

        # 時間差の解消のためのチェック job投入時点のmodelの情報と処理時点のmodelの情報のチェック
        def ready_to_sync?(index_target, sync_request)
            if index_target.are_search_es_index_marked?
                AreSearch.logger.debug { "[AreSearch] sync: index 操作中のためスキップ #{index_target.model_class.name} #{index_target.target_name} #{sync_request.ar_instance_key}" }

                update_sync_request_last_error(sync_request, "index marked")

                return false
            end

            unless AreSearch::IndexManager.es_index_alias_exists?(sync_request.es_index_name)
                AreSearch.logger.debug { "[AreSearch] sync: index が存在しないためスキップ #{index_target.model_class.name} #{index_target.target_name} #{sync_request.ar_instance_key}" }

                update_sync_request_last_error(sync_request, "index not found")

                return false
            end

            true
        end

        # 処理中フラグを立てる
        def acquire_sync_request_processing(sync_request, processing_token)
            updated_count = current_sync_request_relation(sync_request)
                .where("processing_token IS NULL OR processing_token = ?", processing_token)
                .update_all(
                    processing_token: processing_token,
                    processing_at:    Time.zone.now,
                )

            updated_count == 1
        end

        def release_current_processing(sync_request)
            AreSearch::SyncRequest
                .where(id: sync_request.id)
                .update_all(
                    processing_token: nil,
                    processing_at:    nil,
                )
        end

        # find_sync_request で取得した sync_request のキー項目は、
        # sync の引数 model / index_target_name / ar_instance_key / es_index_name から作られているため、実質syncの引数を直接渡すのと同じ。
        # 意味的にはsyncの引数を渡すべきだが、引数を減らすため流用。
        # force の場合は、sync_requestが削除後に再生成されている可能性もあるが、
        # エラーの発生の記録は残したいので sync_request.id ではなく対象特定条件にする
        #
        # ここでは request_sequence で世代固定せず、同じ同期キーの現在行に last_error を書く。
        def update_sync_request_last_error(sync_request, message)
            AreSearch::SyncRequest
                .where(
                    ar_model_class_name: sync_request.ar_model_class_name,
                    index_target_name:   sync_request.index_target_name,
                    ar_instance_key:     sync_request.ar_instance_key,
                    es_index_name:       sync_request.es_index_name,
                ).update_all(last_error: message)
        end

        # 世代が変わっている場合は、次の世代の同期が処理するので記録しない
        # リクエスト残留時に何が問題なのかわからなくなる
        def update_sync_request_error(sync_request, error)
            current_sync_request_relation(sync_request).update_all(
                retry_count: sync_request.retry_count + 1,
                last_error:  error.message,
            )
        end

        def update_force_attempt_request_error(sync_request, error)
            current_sync_request_relation(sync_request).update_all(
                last_error:  error.message,
            )
        end
    end
end
