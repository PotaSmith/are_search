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
        # run_sync_requests_XXXX は1件の失敗で全体を止めないため、こちらを使う。
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

    class SyncRequest < ActiveRecord::Base

        self.table_name = "are_search_sync_requests"

        # run_sync_requests_XXXX が通常同期で使用する固定 token。
        # Job / direct が使用する UUID と区別し、rake 異常中断後は次回 rake が再開する。
        RAKE_PROCESSING_TOKEN = "rake task"

        # 通常同期の試行上限に到達し、現在の要求世代も再試行対象ではないSyncRequestを返す。
        def self.sync_try_limit_reached
            AreSearch::SyncRequest
                .where("sync_try_count >= ?", AreSearch.max_sync_try_count)
                .where("last_sync_try_at IS NULL OR last_sync_try_at >= request_sequence_at")
        end

        # processing中のままforce同期の試行上限に到達したSyncRequestを返す。
        def self.force_try_limit_reached
            AreSearch::SyncRequest
                .where.not(processing_token: nil)
                .where("force_try_count >= ?", AreSearch.max_force_try_count)
        end

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
            AreSearch::SyncRequest::Sync.new(self).try_sync(processing_token, on_rake: on_rake, reraise: reraise)
        end

        def are_search_try_force_sync
            AreSearch::SyncRequest::Sync.new(self).try_force_sync
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
