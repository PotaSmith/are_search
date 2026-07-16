# frozen_string_literal: true

require "securerandom"
require "socket"

module AreSearch

# frozen_string_literal: true

require "securerandom"
require "socket"

module AreSearch
    # Elasticsearch index操作中であることをPostgreSQL上に残すmarker。
    #
    # 1つのes_index_nameにつき、最大1行だけ存在する。
    #
    # markerが存在する間は、通常同期、reindex、clean upなど、
    # 同じindexを書き換える処理を開始しない。
    # 検索処理自体はmarkerの存在では停止しない。
    #
    # flockは、同じlockファイルを参照できるプロセス間の同時実行を防ぐ。
    # IndexMarkerは、DBから確認できる操作状態と、異常終了時の痕跡を残す。
    #
    # 正常終了時にはmarkerを削除する。
    # プロセス停止などにより削除されなかったmarkerは、
    # 状態確認と手動復旧の対象になる。
    #
    #
    # owner_token
    # ----------------------------------------------------------------
    #
    # owner_tokenは、markerを作成した処理を識別する所有者token。
    #
    # 正常終了時のmarker削除では、idとowner_tokenの両方を条件にする。
    # markerの所有者が変わっていた場合は、古い処理から削除しない。
    #
    # SyncRequestのprocessing_tokenとは役割が異なる。
    #
    #     SyncRequest.processing_token
    #         通常同期の多重実行を防ぐための排他処理用フラグ。
    #
    #     IndexMarker.owner_token
    #         自分が作成したmarkerだけを削除するための所有者識別値。
    #
    #
    # DBフィールド
    # ----------------------------------------------------------------
    #
    # id
    #     IndexMarker行の主キー。
    #
    # es_index_name
    #     操作対象のElasticsearch alias名。
    #     unique indexにより、同じindexにはmarkerを1件だけ作成できる。
    #
    # operation
    #     実行中または残留している操作名。
    #     reindex、clean_up、manualのほか、
    #     are_search_es_with_index_guardへ渡した操作名を保持する。
    #
    # owner_token
    #     markerを作成した処理の所有者識別値。
    #     正常終了時に、自分が作成したmarkerだけを削除するために使用する。
    #
    # owner_host
    #     markerを作成したプロセスのホスト名。
    #     異常終了時の状態確認に使用する。
    #
    # owner_pid
    #     markerを作成したプロセスのPID。
    #     操作中のプロセスが残っているか確認するために使用する。
    #
    # started_at
    #     index操作を開始してmarkerを作成した時刻。
    #
    # message
    #     markerへ付加する任意の診断メッセージ。
    #     排他判定や所有者判定には使用しない。
    #
    # created_at
    #     marker行を作成した時刻。
    #
    # updated_at
    #     Railsが管理するmarker行の更新時刻。
    #     操作開始時刻にはstarted_atを使用する。
    #

    class IndexMarker < ActiveRecord::Base
        self.table_name = "are_search_index_markers"

        MANUAL_OPERATION = "manual"

        def self.marked?(es_index_name)
            AreSearch::IndexMarker.exists?(es_index_name: es_index_name)
        end

        # IndexManager から呼ばれる内部用の marker lifecycle API。
        # public class method だが、利用側アプリから直接呼ぶ想定ではない。
        # public に見えるため、このメソッド自身でも index_operation_enabled を確認する。
        def self.with_index_operation_marker!(es_index_name, operation:)
            AreSearch::IndexManager.validate_index_operation_enabled!

            raise AreSearch::IndexMarkerUnavailable if marked?(es_index_name)

            marker = create_for_index_operation!(
                es_index_name,
                operation: operation,
            )

            begin
                return yield
            ensure
                delete_if_owner!(marker)
            end
        end

        def self.create_manual!(es_index_name)
            AreSearch::IndexManager.validate_index_operation_enabled!

            return nil if marked?(es_index_name)

            create_for_index_operation!(
                es_index_name,
                operation: MANUAL_OPERATION,
            )
        rescue AreSearch::IndexMarkerUnavailable
            nil
        end

        def self.delete_manual!(es_index_name)
            AreSearch::IndexManager.validate_index_operation_enabled!

            AreSearch::IndexMarker.where(
                es_index_name: es_index_name,
                operation:     MANUAL_OPERATION,
            ).delete_all
        end

        def self.delete_force!(es_index_name)
            AreSearch::IndexManager.validate_index_operation_enabled!

            AreSearch::IndexMarker.where(
                es_index_name: es_index_name,
            ).delete_all
        end

        def self.create_for_index_operation!(es_index_name, operation:)
            AreSearch::IndexMarker.create!(
                es_index_name: es_index_name,
                operation:     operation,
                owner_token:   SecureRandom.uuid,
                owner_host:    current_host_name,
                owner_pid:     Process.pid,
                started_at:    Time.zone.now,
            )
        rescue ActiveRecord::RecordNotUnique
            raise AreSearch::IndexMarkerUnavailable, "index marker already exists: #{es_index_name}"
        end
        private_class_method :create_for_index_operation!

        def self.delete_if_owner!(marker)
            AreSearch::IndexMarker.where(
                id:          marker.id,
                owner_token: marker.owner_token,
            ).delete_all
        end
        private_class_method :delete_if_owner!

        def self.current_host_name
            Socket.gethostname
        rescue StandardError
            nil
        end
        private_class_method :current_host_name
    end
end
