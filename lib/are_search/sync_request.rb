# frozen_string_literal: true

module AreSearch
    class IndexTarget

        # sync_request 1件分の同期を実行する
        #
        # 先頭で reindex 中かを確認し、reindex 中であれば同期をスキップする。
        # スキップ時は外から見ると成功扱い（例外を出さず正常 return）。
        # SyncRequest は消えず、last_error に reindex 中である旨を記録する。
        # *_try_count は増やさない。
        #
        # reindex 中でない場合は DBから ar_instance_key で再取得し、
        # 存在すればindex、存在しなければdeleteする。
        # 成功時はsync_requestを削除し、失敗時は last_errorを更新する。
        #
        # reraise: true の場合、失敗時に last_error を更新した上で
        # 例外を呼び出し元へ再送出する。SyncJob から retry_on を効かせるために使う。
        # reraise: false（デフォルト）の場合は例外を握りつぶす。rake タスクの
        # run_sync_requests は1件の失敗で全体を止めないため、こちらを使う。
        #
        def are_search_sync(ar_instance_key, sync_stage_name, reraise: false)
            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncRequest.find_and_try_sync(
                model_class.name,
                ar_instance_key,
                are_search_index_alias_name,
                sync_stage_name,
                SecureRandom.uuid,
                reraise: reraise,
            )
        end

        # このIndexTargetで処理中のSyncRequestが存在するか返す。
        def are_search_processing_sync_request_exists?
            AreSearch::SyncRequest.where(
                index_alias_name: are_search_index_alias_name,
            ).where.not(
                processing_token: nil,
            ).exists?
        end

       # このIndexTargetの指定stageで処理中のSyncRequestが存在するか返す。
         def are_search_processing_sync_stage_sync_request_exists?(sync_stage_name)
            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncRequest.where(
                index_alias_name: are_search_index_alias_name,
                sync_stage_name:  sync_stage_name,
            ).where.not(
                processing_token: nil,
            ).exists?
        end
    end

    # 以下は、are_search_try_sync、are_search_try_force_sync 以外直接呼ばない

    class SyncRequest < ActiveRecord::Base

        self.table_name = "are_search_sync_requests"

        # run_sync_requests が通常同期で使用する固定 token。
        # Job / direct が使用する UUID と区別し、rake 異常中断後は次回 rake が再開する。
        RAKE_PROCESSING_TOKEN = "rake task"

        def self.find_and_try_sync(ar_model_class_name, ar_instance_key, index_alias_name, sync_stage_name, processing_token, reraise: false)

            # sync処理時点の、おそらく自分の処理対象であろうと思われる SyncRequest を取得する。
            # Job の場合は投入時点から時間差があるため、現在の SyncRequest を取り直す。
            sync_request = AreSearch::SyncRequest.find_by(
                ar_model_class_name: ar_model_class_name,
                ar_instance_key:     ar_instance_key.to_s,
                index_alias_name:    index_alias_name,
                sync_stage_name:     sync_stage_name,
            )

            # 他で処理をしている。ここで処理してない事がわかるようにfalseを返す
            return false if sync_request.nil?

            sync_request.are_search_try_sync(processing_token, on_rake: false, reraise: reraise)
        end

        def are_search_try_sync(processing_token, on_rake: true, reraise: false)
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
                return false if index_target.are_search_before_sync_check(ar_instance_key, self) == false

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
                index_target.are_search_after_sync_callback(record, self)

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

        def are_search_try_force_sync
            # 対象外
            return false if processing_token.blank?

            index_target = resolve_index_target_nilable

            # index_targetがnilの場合は、現在のモデル定義からtargetがなくなった可能性があるため、要求は消さずに残す
            return false if check_sync_index_target?(index_target) == false
            return false if check_sync_stage_name?(index_target) == false

            return false if check_index_target_ready?(index_target) == false

            #同期が許可されているかを確認する。
            return false if check_index_target_sync_ready?(index_target) == false

            # 他の sync_stage_name で sync_request が存在しないか等のチェックを行うための callback
            return false if index_target.are_search_before_sync_check(ar_instance_key, self) == false

            # force が処理したフラグ
            updated_count = sync_request_relation_no_sequence
                .where(processing_token: processing_token)
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
            model = ar_model_class_name.safe_constantize
            return nil if model.nil?
            return nil unless model.respond_to?(:are_search_index_target)

            model.are_search_index_target(index_target_name)
        end

        def find_record_by_ar_instance_key(index_target)
            index_target.model_class.find_by(id: ar_instance_key)
        end

        def sync_or_delete_if_record_is_nil(record, index_target)
            if record != nil
                record.are_search_index_or_delete!(index_target, sync_stage_name)
            else
                index_target.are_search_delete!(ar_instance_key)
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
            AreSearch::SyncRequest.where(id: id)
        end

        def sync_request_relation_with_sequence
            AreSearch::SyncRequest.where(id: id, request_sequence: request_sequence)
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
                AreSearch.logger.debug { "[AreSearch] sync: index targetが存在しないためスキップ #{self.ar_model_class_name} #{self.index_target_name} #{self.ar_instance_key}" }

                update_sync_request_error_no_sequence("index_target not found")

                return false
            end

            if index_target.are_search_index_alias_name.to_s != self.index_alias_name.to_s
                AreSearch.logger.debug { "[AreSearch] sync: index_alias_name が 異なるためスキップ #{self.ar_model_class_name} #{self.index_alias_name}[sync_request] != #{index_target.are_search_index_alias_name}[index_target] #{self.ar_instance_key}" }

                update_sync_request_error_no_sequence("index_alias_name not match")

                return false
            end

            true
        end

        # SyncRequestのstageが、処理時点のIndexTargetに存在するか確認する。
        def check_sync_stage_name?(index_target)
            sync_stage_names = index_target.are_search_sync_stage_names

            return true if sync_stage_names.include?(self.sync_stage_name)

            AreSearch.logger.debug { "[AreSearch] sync: sync_stage_name が存在しないためスキップ #{self.ar_model_class_name} #{self.index_target_name} #{self.sync_stage_name} #{self.ar_instance_key}" }

            update_sync_request_error_no_sequence("sync_stage_name not found")

            false
        end

        # 時間差の解消のためのチェック job投入時点のmodelの情報と処理時点のmodelの情報のチェック
        def check_index_target_ready?(index_target)
            if index_target.are_search_index_alias_exists? == false
                AreSearch.logger.debug { "[AreSearch] sync: index が存在しないためスキップ #{index_target.model_class.name} #{index_target.index_target_name} #{self.ar_instance_key}" }

                update_sync_request_error_no_sequence("index not found")

                return false
            end

            true
        end

        # 同期が許可されているかを確認
        def check_index_target_sync_ready?(index_target)
            if index_target.are_search_sync_stage_syncable?(sync_stage_name) == false
                AreSearch.logger.debug { "[AreSearch] sync: sync lock 中のためスキップ #{index_target.model_class.name} #{index_target.index_target_name} #{self.ar_instance_key}" }

                update_sync_request_error_no_sequence("sync locked")

                return false
            end

            true
        end
    end
end

# Elasticsearchへの未完了の同期要求を表す。
#
# 1行は、次の同期キーに対する未完了要求を保持する。
#
#     index_alias_name
#     sync_stage_name
#     ar_instance_key
#
# 同じ同期キーへの新しい要求は新しい行を作らず、既存行へupsertする。
# そのため、1行の中で要求の世代、処理中状態、force処理状態を管理する。
#
#
# request_sequence
# ----------------------------------------------------------------
#
# request_sequenceは、処理を開始した時点の要求を削除してよいか確認するための
# 世代番号。
#
# 同期処理中に同じ同期キーへ新しい要求が発生した場合、
# 同じ行のrequest_sequenceが更新される。
#
# 同期完了時は、処理開始時に取得したrequest_sequenceを削除条件に含める。
# 現在のrequest_sequenceが変わっていなければ、処理した要求を削除する。
# 新しい要求によってrequest_sequenceが変わっていれば、その行は削除せず残す。
#
# request_sequenceはprocessing状態の所有者を表す値ではない。
#
#
# processing_token
# ----------------------------------------------------------------
#
# processing_tokenは、同じ同期要求に対する通常同期の多重実行を防ぐための
# 排他処理用フラグ。
#
# 通常は、processing_tokenが存在する間に別の処理から上書きされることはない。
# processing_atと組み合わせて、処理中のまま戻らない要求の検出にも使用する。
#
# Jobは引数にprocessing_tokenを保持したままリトライされる。
# DB上に同じprocessing_tokenが残っている場合は同一処理の再開とみなし、
# 排他取得済みの状態でも処理を再開できる。
#
# 同期処理が正常終了した場合は、現在行のprocessing_tokenとprocessing_atを
# 解除する。
#
# 解除時に、処理開始時のrequest_sequenceやprocessing_tokenは条件に含めない。
#
# 万が一、排他中のprocessing状態が別の処理によって横取り・変更されていた場合でも、
# 正常終了した同期処理がprocessing状態を残すと、その後の同期が一切開始できなくなる。
#
# そのため、正常終了または例外終了まで到達した同期処理は、
# 現在行に残っているprocessing状態を解除する。
#
#
# force_attempted
# ----------------------------------------------------------------
#
# force_attemptedは、処理中のまま古くなった要求に対して、
# force同期が介入した状態であることを表すフラグ。
#
# after_commitから実行されるdirect処理やJob処理は並列に動作し、
# force同期との間に時間差が発生する可能性がある。
#
# そのため、after_commit系の通常処理は、
# force_attemptedがtrueの要求を同期成功だけでは削除しない。
#
# 要求はrakeの回収処理まで残し、rake側の同期が正常終了した時点で削除する。
# rake処理は残留要求を回収する正規の復旧経路であるため、
# force_attemptedの有無にかかわらず、処理した世代の要求を削除できる。
# JobではJobの遅延や復旧での割り込みの可能性があるため削除しない。
#
#
# DBフィールド
# ----------------------------------------------------------------
#
# id
#     SyncRequest行の主キー。
#     同じ同期キーへの新しい要求は既存行へupsertされるため、
#     要求の世代が変わってもidは変わらない。
#
# index_alias_name
#     同期要求作成時のElasticsearch alias名。
#
# ar_model_class_name
#     同期対象レコードのActive Recordモデル名。
#
# ar_instance_key
#     同期対象レコードの主キーをString化した値。
#
# sync_stage_name
#     同期処理で使用するstage名。
#     同じindex・モデル・レコードでも、stageごとに独立した同期要求を保持する。
#
# index_target_name
#     同期対象のIndexTarget名。
#     同期実行時に現在のIndexTargetを解決するために使用する。
#
# request_sequence
#     同期要求の世代番号。
#     同期完了時に、処理した要求を削除してよいか確認するために使用する。
#
# request_sequence_at
#     現在のrequest_sequenceが発行された時刻。
#
# processing_token
#     通常同期の多重実行を防ぐための排他処理用フラグ。
#
# processing_at
#     processing_tokenを設定して通常同期を開始した時刻。
#     処理中のまま古くなった要求をforce対象として検出するために使用する。
#
# sync_try_count
#     Elasticsearchへの同期処理を開始した回数。
#     同期要求全体が正常終了した場合は0へ戻す。
#
# last_sync_try_at
#     最後にElasticsearchへの同期処理を開始した時刻。
#     同期要求全体が正常終了した場合はnilへ戻す。
#
# callback_try_count
#     同期後callbackを開始した回数。
#     同期要求全体が正常終了した場合は0へ戻す。
#
# last_callback_try_at
#     最後に同期後callbackを開始した時刻。
#     同期要求全体が正常終了した場合はnilへ戻す。
#
# last_completed_at
#     同期要求全体が正常終了した時刻。
#
# force_attempted
#     force同期が介入した要求であることを表す。
#     trueの場合、after_commit系の通常処理では要求を削除せず、
#     rakeの回収処理まで残す。
#
# last_force_try_at
#     最後にforce同期を試みた時刻。
#
# force_try_count
#     force同期を試みた回数。
#     force処理の試行上限と状態確認に使用する。
#
# last_error
#     最後に発生した同期エラーまたは同期できなかった理由。
#     新しい同期要求がupsertされても維持し、同期要求全体が正常終了した場合はnilへ戻す。
#
# last_error_at
#     last_errorが書き込まれた時刻。
#
# created_at
#     この同期キーに対する行が最初に作成された時刻。
#
# updated_at
#     Railsが管理する行の更新時刻。
