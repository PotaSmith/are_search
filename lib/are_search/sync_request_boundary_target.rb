# frozen_string_literal: true

module AreSearch
    class IndexTarget

        # 指定stageのBoundaryTargetを取得する。
        def are_search_find_sync_request_boundary_target!(sync_stage_name)
            AreSearch.validate_rake_operation_enabled!

            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncRequestBoundaryTarget.find_by(
                index_alias_name: are_search_index_alias_name,
                sync_stage_name:  sync_stage_name,
            )
        end

        # 指定stageのBoundaryTargetを作成する。
        # 作成時に採番したrequest_sequenceを境界として保存する。
        def are_search_set_sync_request_boundary_target!(sync_stage_name)
            AreSearch.validate_rake_operation_enabled!

            validate_defined_sync_stage_name!(sync_stage_name)

            AreSearch::SyncRequestBoundaryTarget.set_target!(are_search_index_alias_name, sync_stage_name)
        end

        # 指定stageのBoundaryTargetを削除する。
        # stage定義削除後の残留BoundaryTargetも削除できるよう、名前形式だけを検査する。
        def are_search_clear_sync_request_boundary_target!(sync_stage_name)
            AreSearch.validate_rake_operation_enabled!

            AreSearch::IndexDefinition.valid_sync_stage_name!(sync_stage_name)

            AreSearch::SyncRequestBoundaryTarget.clear_target!(are_search_index_alias_name, sync_stage_name)
        end
    end

    # 以下は直接呼ばない

    class SyncRequestBoundaryTarget < ActiveRecord::Base

        self.table_name = "are_search_sync_request_boundary_targets"

        # 指定stageのBoundaryTargetを作成する。
        # 作成時に採番したrequest_sequenceを境界として保存する。
        # 既に存在する場合は例外にする。
        def self.set_target!(index_alias_name, sync_stage_name)
            if target_exists?(index_alias_name, sync_stage_name)
                raise ArgumentError, "SyncRequestBoundaryTarget は既に存在します: #{sync_stage_name}"
            end

            sequence_limit = AreSearch.database_specific.next_request_sequence

            AreSearch::SyncRequestBoundaryTarget.create!(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
                sequence_limit:   sequence_limit,
            )
        end

        # 指定stageのBoundaryTargetを削除する。
        def self.clear_target!(index_alias_name, sync_stage_name)
            AreSearch::SyncRequestBoundaryTarget.where(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
            ).delete_all
        end

        # 指定stageのBoundaryTargetが存在するか確認する。
        def self.target_exists?(index_alias_name, sync_stage_name)
            AreSearch::SyncRequestBoundaryTarget.exists?(
                index_alias_name: index_alias_name,
                sync_stage_name:  sync_stage_name,
            )
        end
        private_class_method :target_exists?
    end
end
