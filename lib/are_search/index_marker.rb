# frozen_string_literal: true

require "securerandom"
require "socket"

module AreSearch
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
