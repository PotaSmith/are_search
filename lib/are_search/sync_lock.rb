# frozen_string_literal: true

require "securerandom"
require "socket"

module AreSearch
    class IndexTarget

        # このIndexTarget全体のmanual sync lockを取得する。
        def are_search_acquire_sync_lock!
            AreSearch.validate_index_operation_enabled!

            AreSearch::SyncLock.acquire_index_target_manual!(are_search_index_alias_name)
        end

        # このIndexTarget全体のがロックされているかを返す。
        def are_search_sync_locked?
            are_search_index_target_syncable? == false
        end

        # このIndexTargetの指定stageへmanual sync lockを取得する。
        def are_search_acquire_sync_stage_lock!(sync_stage_name)
            AreSearch.validate_index_operation_enabled!

            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncLock.acquire_sync_stage_manual!(are_search_index_alias_name, sync_stage_name)
        end

        # このIndexTargetの指定stageへmanual sync がロックされているかを返す。
        def are_search_sync_stage_locked?(sync_stage_name)
            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncLock.sync_stage_locked?(are_search_index_alias_name, sync_stage_name)
        end

        # このIndexTarget全体のmanual sync lockを解放する。
        def are_search_release_sync_lock!
            AreSearch.validate_index_operation_enabled!

            AreSearch::SyncLock.release_index_target_manual!(are_search_index_alias_name)
        end

        # このIndexTargetの指定stageにあるmanual sync lockを解放する。
        # stage定義を削除した後の残留lockも解除できるよう、名前形式だけを検査する。
        def are_search_release_sync_stage_lock!(sync_stage_name)
            AreSearch.validate_index_operation_enabled!

            AreSearch::IndexDefinition.valid_sync_stage_name!(sync_stage_name)

            AreSearch::SyncLock.release_sync_stage_manual!(are_search_index_alias_name, sync_stage_name)
        end

        # この IndexTarget に残っている index target lock を強制解除する。
        # 通常の release で解除できない残留 lock の復旧用途を想定する。
        def are_search_force_release_sync_lock!
            AreSearch.validate_index_operation_enabled!

            AreSearch::SyncLock.force_release!(are_search_index_alias_name)
        end

        # このIndexTargetの指定stageに残っている sync stage sync lock を強制解除する。
        # stage定義を削除した後の残留lockも解除できるよう、名前形式だけを検査する。
        def are_search_force_release_sync_stage_lock!(sync_stage_name)
            AreSearch.validate_index_operation_enabled!

            AreSearch::IndexDefinition.valid_sync_stage_name!(sync_stage_name)

            AreSearch::SyncLock.force_release_sync_stage!(are_search_index_alias_name, sync_stage_name)
        end

        # このIndexTargetへ同期を開始できるか返す。
        def are_search_index_target_syncable?
            AreSearch::SyncLock.index_target_locked?(are_search_index_alias_name) == false
        end

        # このIndexTargetへ同期を開始できるか返す。
        def are_search_sync_stage_syncable?(sync_stage_name)

            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncLock.index_target_or_sync_stage_locked?(are_search_index_alias_name, sync_stage_name) == false
        end

        # 指定stageの sync lock だけを取得し、その内側で利用側処理を実行する。
        # index lock と index target sync lock は取得しない。
        def are_search_with_sync_stage_lock(sync_stage_name, operation:, &block)
            AreSearch.validate_index_operation_enabled!

            validate_defined_sync_stage_name!(sync_stage_name)

            if operation.to_s.empty?
                raise ArgumentError, "operation を指定してください"
            end

            if block.nil?
                raise ArgumentError, "are_search_with_sync_stage_lock には block が必要です"
            end

            # 利用側の指定誤りで、存在しない alias の guard を開始しない。
            if AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: are_search_index_alias_name,
            ) == false
                raise ArgumentError, "indexが存在しません #{are_search_index_alias_name}"
            end

            AreSearch::SyncLock.with_sync_stage_operation!(
                are_search_index_alias_name,
                operation: operation,
                sync_stage_name: sync_stage_name,
                &block
            )
        end
    end

    # 以下は直接呼ばない

    class SyncLock < ActiveRecord::Base

        self.table_name = "are_search_sync_locks"

        MANUAL_OPERATION = "manual"
        INDEX_TARGET_LOCK_NAME = "index target lock"

        private_constant :INDEX_TARGET_LOCK_NAME

        def self.index_target_lock_name
            INDEX_TARGET_LOCK_NAME
        end

        def self.index_target_lock_sync_stage_name?(sync_stage_name)
            sync_stage_name == INDEX_TARGET_LOCK_NAME
        end

        def self.index_target_locked?(index_alias_name)
            AreSearch::SyncLock.exists?(
                index_alias_name: index_alias_name,
                sync_stage_name:  INDEX_TARGET_LOCK_NAME,
            )
        end

        def self.sync_stage_locked?(index_alias_name, sync_stage_name)
            AreSearch::SyncLock.exists?(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
            )
        end

        def self.index_target_or_sync_stage_locked?(index_alias_name, sync_stage_name)
            AreSearch::SyncLock.exists?(
                index_alias_name: index_alias_name,
                sync_stage_name:  [sync_stage_name, INDEX_TARGET_LOCK_NAME],
            )
        end

        # IndexManager から呼ばれる内部用の sync lock lifecycle API。
        # public class method だが、利用側アプリから直接呼ぶ想定ではない。
        # index_operation_enabled を確認しない。かならず呼び出し元から確認すること。
        def self.with_index_operation!(index_alias_name, operation:, &block)
            raise AreSearch::SyncLockUnavailable if index_target_lock_exists?(index_alias_name)

            sync_lock = acquire_sync_lock!(index_alias_name, operation, INDEX_TARGET_LOCK_NAME)

            begin
                return block.call
            ensure
                release_if_owner!(sync_lock)
            end
        end

        # 利用側処理を sync stage lock の内側で実行する。
        # index lock と index target sync lock は取得しない。
        def self.with_sync_stage_operation!(index_alias_name, operation:, sync_stage_name:, &block)
            raise AreSearch::SyncLockUnavailable if sync_stage_lock_exists?(index_alias_name, sync_stage_name)

            sync_lock = acquire_sync_lock!(index_alias_name, operation, sync_stage_name)

            begin
                return block.call
            ensure
                release_if_owner!(sync_lock)
            end
        end

        def self.acquire_index_target_manual!(index_alias_name)
            return nil if index_target_lock_exists?(index_alias_name)

            # 手動指定の誤りで、存在しない alias の sync lock を取得しない。
            return nil if AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: index_alias_name,
            ) == false

            acquire_sync_lock!(index_alias_name, MANUAL_OPERATION, INDEX_TARGET_LOCK_NAME)
        rescue AreSearch::SyncLockUnavailable
            nil
        end

        def self.acquire_sync_stage_manual!(index_alias_name, sync_stage_name)
            return nil if sync_stage_lock_exists?(index_alias_name, sync_stage_name)

            # 手動指定の誤りで、存在しない alias の sync lock を取得しない。
            return nil if AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: index_alias_name,
            ) == false

            acquire_sync_lock!(index_alias_name, MANUAL_OPERATION, sync_stage_name)
        rescue AreSearch::SyncLockUnavailable
            nil
        end

        def self.release_index_target_manual!(index_alias_name)
            AreSearch::SyncLock.where(
                index_alias_name: index_alias_name,
                sync_stage_name:  INDEX_TARGET_LOCK_NAME,
                operation:        MANUAL_OPERATION,
            ).delete_all
        end

        def self.release_sync_stage_manual!(index_alias_name, sync_stage_name)
            AreSearch::SyncLock.where(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
                operation:        MANUAL_OPERATION,
            ).delete_all
        end

        def self.force_release!(index_alias_name)
            AreSearch::SyncLock.where(
                index_alias_name: index_alias_name,
                sync_stage_name:  INDEX_TARGET_LOCK_NAME,
            ).delete_all
        end

        def self.force_release_sync_stage!(index_alias_name, sync_stage_name)
            AreSearch::SyncLock.where(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
            ).delete_all
        end

        def self.index_target_lock_exists?(index_alias_name)
            AreSearch::SyncLock.exists?(
                index_alias_name: index_alias_name,
                sync_stage_name:  INDEX_TARGET_LOCK_NAME,
            )
        end
        private_class_method :index_target_lock_exists?

        def self.sync_stage_lock_exists?(index_alias_name, sync_stage_name)
            AreSearch::SyncLock.exists?(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
            )
        end
        private_class_method :sync_stage_lock_exists?

        def self.acquire_sync_lock!(index_alias_name, operation, sync_stage_name)
            AreSearch::SyncLock.create!(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
                operation:        operation,
                owner_token:      SecureRandom.uuid,
                owner_host:       current_host_name,
                owner_pid:        Process.pid,
                started_at:       Time.zone.now,
            )
        rescue ActiveRecord::RecordNotUnique
            raise AreSearch::SyncLockUnavailable, "sync lock already exists: #{index_alias_name}"
        end
        private_class_method :acquire_sync_lock!

        def self.release_if_owner!(sync_lock)
            AreSearch::SyncLock.where(
                id:          sync_lock.id,
                owner_token: sync_lock.owner_token,
            ).delete_all
        end
        private_class_method :release_if_owner!

        def self.current_host_name
            Socket.gethostname
        rescue StandardError
            nil
        end
        private_class_method :current_host_name
    end
end

# Elasticsearch indexへの同期や操作を制御するためのsync lock。
#
# index_alias_name と sync_stage_name の組み合わせごとに、最大1行だけ存在する。
#
# index target sync lock が存在する間は、通常同期、reindex、clean upなど、
# 同じ index を書き換える処理を開始しない。
# 検索処理自体は sync lock の存在では停止しない。
#
# index lock は、同じlockファイルを参照できる処理間の同時実行を防ぐ。
# SyncLock は、DBから確認できる操作状態と、異常終了時の痕跡を残す。
#
# 正常終了時には sync lock を解放する。
# プロセス停止などにより解放されなかった sync lock は、
# 状態確認と手動復旧の対象になる。
#
#
# owner_token
# ----------------------------------------------------------------
#
# owner_tokenは、sync lockを取得した処理を識別する所有者token。
#
# 正常終了時のsync lock解放では、idとowner_tokenの両方を条件にする。
# sync lockの所有者が変わっていた場合は、古い処理から削除しない。
#
# SyncRequestのprocessing_tokenとは役割が異なる。
#
#     SyncRequest.processing_token
#         通常同期の多重実行を防ぐための排他処理用フラグ。
#
#     SyncLock.owner_token
#         自分が取得したsync lockだけを解放するための所有者識別値。
#
#
# DBフィールド
# ----------------------------------------------------------------
#
# id
#     SyncLock行の主キー。
#
# index_alias_name
#     操作対象のElasticsearch alias名。
#
# sync_stage_name
#     sync lockの対象stage名。
#     alias全体を対象にするsync lockでは内部値の "index target lock" を使用する。
#
# operation
#     実行中または残留している操作名。
#     reindex、clean_up、manualのほか、
#     with_index_guard_base や with_sync_stage_operation へ渡した操作名を保持する。
#
# owner_token
#     sync lockを取得した処理の所有者識別値。
#     正常終了時に、自分が取得したsync lockだけを解放するために使用する。
#
# owner_host
#     sync lockを取得したプロセスのホスト名。
#     異常終了時の状態確認に使用する。
#
# owner_pid
#     sync lockを取得したプロセスのPID。
#     操作中のプロセスが残っているか確認するために使用する。
#
# started_at
#     sync lockを取得した時刻。
#
# message
#     sync lockへ付加する任意の診断メッセージ。
#     排他判定や所有者判定には使用しない。
#
# created_at
#     sync lock行を作成した時刻。
#
# updated_at
#     Railsが管理するsync lock行の更新時刻。
#     操作開始時刻にはstarted_atを使用する。
#
