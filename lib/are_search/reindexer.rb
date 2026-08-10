# frozen_string_literal: true

begin
    require "progress_bar"
rescue LoadError
    # progress_bar が無い場合は進捗表示なし
end

module AreSearch
    class IndexTarget

        # 全件をElasticsearchに投入する（移行時・スキーマ変更時に実行する）。
        #
        # flock と IndexMarker の管理は IndexManager.reindex に委ね、
        # その内側で create とバッチ投入を実行する。
        #
        # flock または marker を取得できない場合も、未実行理由を result Hash に残す。
        #
        # reindex の内側（flock 取得済み・IndexMarker 作成済み）で
        # 新しい physical index を作成し、その physical index へ bulk 投入する。
        # block が true を返した場合のみ、IndexManager 側で alias の切り替えを試みる。
        #
        # stage_position には :first または :last を指定する。
        # are_search_all_sync_stage_names に定義された順序から、reindexに使うstageを選ぶ。
        #
        # @return [Hash]
        #   :result      : :success または :not_success
        #   :message     : 失敗理由
        #   :failed_ids  : インデックス失敗した ID の配列
        #   :stop_phase  : 停止した処理段階。成功時は nil
        #   :done_phases : 完了した処理段階
        def are_search_reindex(stage_position:)
            sync_stage_names = model_class.are_search_get_all_sync_stage_names(index_target_name)

            sync_stage_name = nil

            case stage_position
            when :first
                sync_stage_name = sync_stage_names.first
            when :last
                sync_stage_name = sync_stage_names.last
            else
                raise ArgumentError, "stage_position は :first または :last を指定してください"
            end

            AreSearch::Reindexer.reindex_index_target(self, sync_stage_name)
        end
    end

    module Reindexer
        extend self

        def reindex_index_target(index_target, sync_stage_name)
            validate_arguments!(index_target, sync_stage_name)

            result = {
                result: :not_success,
                message: '',
                failed_ids: [],
                stop_phase: nil,
                done_phases: [],
            }

            AreSearch::IndexManager.reindex(
                index_target.are_search_index_alias_name,
                index_target.are_search_index_settings,
                index_target.are_search_index_mappings_for_index,
                'reindex',
                result,
            ) do |physical_index_name|
                bulk_index_target(index_target, sync_stage_name, physical_index_name, result)
            end

            result
        end

        private

        # Reindexerが使用する対象と実行設定を確認する。
        def validate_arguments!(index_target, sync_stage_name)
            unless index_target.instance_of?(AreSearch::IndexTarget)
                raise ArgumentError, "index_target は AreSearch::IndexTarget を指定してください"
            end

            model_class = index_target.model_class

            # 同じ alias を共有する上位モデルの全レコードを欠落させないため、
            # Searchable を継承した子クラスの IndexTarget を拒否する。
            if model_class.superclass&.include?(AreSearch::Searchable)
                raise AreSearch::Error,
                    "Searchable を継承した子クラスから reindex は実行できません: #{model_class.name}"
            end

            sync_stage_names = model_class.are_search_get_all_sync_stage_names(
                index_target.index_target_name,
            )
            unless sync_stage_names.include?(sync_stage_name)
                raise ArgumentError,
                    "sync_stage_name が IndexTarget に定義されていません: #{sync_stage_name}"
            end
        end

        def bulk_index_target(index_target, sync_stage_name, physical_index_name, result)
            total      = index_target.model_class.count
            bar        = nil
            failed_ids = []

            if total != 0 && defined?(::ProgressBar)
                bar = ::ProgressBar.new(total) if ::ProgressBar.respond_to?(:new)
            end

            index_target.model_class.find_in_batches(batch_size: AreSearch.batch_size) do |batch|
                body, ids = build_bulk_body(index_target, sync_stage_name, batch, physical_index_name)
                bar.increment!(batch.size) if bar.respond_to?(:increment!)

                next if body.empty?

                response = AreSearch::EsAdapter.no_validation_bulk(body: body)

                validate_bulk_response!(response, ids)
                collect_bulk_errors(response, ids, failed_ids)
            end

            if failed_ids.empty?
                return true
            else
                result[:failed_ids] = failed_ids
                return false
            end
        end

        def build_bulk_body(index_target, sync_stage_name, batch, physical_index_name)
            body = []
            ids = []

            batch.each do |record|
                next if record.are_search_indexable?(index_target.index_target_name, sync_stage_name) != true

                body << { index: { _index: physical_index_name, _id: record.id.to_s } }
                body << record.are_search_index_data_for_index!(index_target, sync_stage_name)
                ids << record.id
            end

            [body, ids]
        end

        # bulk responseが送信したIDと1対1で対応していることを確認する。
        def validate_bulk_response!(response, expected_ids)
            unless response.respond_to?(:[])
                raise AreSearch::Error, "Elasticsearch bulk response が不正です"
            end

            items = response["items"]
            unless items.instance_of?(Array)
                raise AreSearch::Error, "Elasticsearch bulk response の items が不正です"
            end

            unless items.length == expected_ids.length
                raise AreSearch::Error, "Elasticsearch bulk response の件数が一致しません"
            end

            items.each_with_index do |item, index|
                unless item.instance_of?(Hash)
                    raise AreSearch::Error, "Elasticsearch bulk response の item が不正です"
                end

                result = item["index"]
                unless result.instance_of?(Hash)
                    raise AreSearch::Error, "Elasticsearch bulk response の index 結果が不正です"
                end

                unless result["_id"] == expected_ids[index].to_s
                    raise AreSearch::Error, "Elasticsearch bulk response の ID が一致しません"
                end
            end
        end

        def collect_bulk_errors(response, ids, failed_ids)
            return unless response["errors"]

            response["items"].each do |item|
                op = item["index"] || item["create"] || item["update"] || item["delete"]
                next unless op&.dig("error")

                # この find は上でチェックしてるから失敗しない
                failed_ids << ids.find{|a| a.to_s == op["_id"] }
                AreSearch.logger.error { "[AreSearch] bulk index failed: id=#{op["_id"]} error=#{op["error"].inspect}" }
            end
        end
    end
end
