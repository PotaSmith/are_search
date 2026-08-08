# frozen_string_literal: true

module AreSearch
    module RakeUtils
        module ReindexAllForEsVersionUp
            extend self

            # 未処理の sync request が残っていないことを確認する。
            def validate_no_sync_requests!
                sync_request_count = AreSearch::SyncRequest.count

                return if sync_request_count == 0

                raise AreSearch::Error,
                    "[AreSearch] are_search_sync_requests に #{sync_request_count} 件残っているため reindex できません"
            end

            # Searchable の全継承系統から、reindex を担当する最上位モデルの
            # index target だけを重複なく返す。
            def searchable_index_targets_for_reindex
                # Searchable を直接 include したモデルだけでなく、
                # 継承によって Searchable になった子孫モデルもすべて取得する。
                searchable_models = AreSearch::RakeUtils.all_searchable_include_models

                # STI では最上位モデルの relation に子孫モデルも含まれるため、
                # 各 Searchable 継承系統の最上位モデルだけを reindex 対象にする。
                # model < other_model は、直接の親だけでなく祖先全体を判定する。
                reindex_models = AreSearch::RakeUtils.searchable_root_models(searchable_models)

                index_targets = []
                index_alias_names = []

                # 独立した継承系統の最上位モデル同士で同じ index 名が使われていれば、
                # どちらを reindex 対象にするか決められないためエラーにする。
                reindex_models.each do |model|
                    model.are_search_index_targets.each do |index_target|
                        index_alias_name = index_target.are_search_index_alias_name

                        if index_alias_names.include?(index_alias_name)
                            raise AreSearch::Error,
                                "[AreSearch] reindex 対象の index が複数の上位モデルで重複しています: #{index_alias_name}"
                        end

                        index_alias_names << index_alias_name
                        index_targets << index_target
                    end
                end

                index_targets
            end

            # AreSearch の prefix に属する index のうち、
            # 現在の alias に接続されていない index が存在しないことを確認する。
            def validate_no_unconnected_indexes!(index_targets)
                searchable_index_alias_names = index_targets.map(&:are_search_index_alias_name)
                actual_index_names = actual_index_names_for_prefix
                current_physical_index_names = []

                searchable_index_alias_names.each do |index_alias_name|
                    physical_index_names = AreSearch::IndexManager.physical_index_names_by_alias(index_alias_name)
                    current_physical_index_names.concat(physical_index_names)
                end

                unconnected_index_names = actual_index_names - current_physical_index_names
                unconnected_index_names.sort!

                return if unconnected_index_names.empty?

                message = "[AreSearch] 管理対象外または未接続の index が残っているため reindex できません:\n"
                unconnected_index_names.each do |index_name|
                    message += "  #{index_name}\n"
                end

                raise AreSearch::Error, message.rstrip
            end

            private

            # AreSearch の index_prefix 配下に存在する Elasticsearch index 名を返す。
            def actual_index_names_for_prefix
                response = AreSearch::EsAdapter.indices_for_prefix(
                    index_prefix: AreSearch.index_prefix,
                )

                response.keys
            end
        end
    end
end
