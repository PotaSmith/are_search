# frozen_string_literal: true

module AreSearch
    module EsAdapter
        extend self

        def success
            :success
        end

        def not_success
            :not_success
        end

        def not_found
            :not_found
        end

        # 呼び出し元で検査済みの引数を使って Elasticsearch の検索APIを呼び出す。
        def no_validation_search(index:, body:)
            AreSearch.client.search(index: index, body: body)
        end

        # Elasticsearch の単一ドキュメント登録APIを呼び出す。
        def index(index_alias_name:, id:, body:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.index(index: index_alias_name, id: id, body: body)
        end

        # Elasticsearch の単一ドキュメント削除APIを呼び出す。
        def delete(index_alias_name:, id:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            response = AreSearch.client.delete(index: index_alias_name, id: id)

            if response["result"] == 'deleted'
                return success
            else
                return not_success
            end
        rescue Elastic::Transport::Transport::Errors::NotFound
            return not_found
        end

        # 呼び出し元で検査済みのbodyを使って Elasticsearch のbulk APIを呼び出す。
        def no_validation_bulk(body:)
            AreSearch.client.bulk(body: body)
        end

        # Elasticsearch のalias取得APIを呼び出す。
        def indices_get_alias(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.indices.get_alias(name: index_alias_name)
        rescue Elastic::Transport::Transport::Errors::NotFound
            {}
        end

        # 指定aliasから生成された物理indexを取得する。
        def physical_indices_for_alias(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            index_pattern = "#{index_alias_name}#{AreSearch::IndexDefinition::INDEX_NAME_DELIMITER}*"

            AreSearch.client.indices.get(index: index_pattern)
        rescue Elastic::Transport::Transport::Errors::NotFound
            {}
        end

        # 指定index_prefix配下のindexを取得する。
        def indices_for_prefix(index_prefix:)
            AreSearch::IndexDefinition.valid_index_prefix!(index_prefix)

            index_pattern = "#{index_prefix}#{AreSearch::IndexDefinition::INDEX_NAME_DELIMITER}*"

            AreSearch.client.indices.get(index: index_pattern)
        rescue Elastic::Transport::Transport::Errors::NotFound
            {}
        end

        # alias名と同名の物理indexを取得する。
        def alias_named_physical_index(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.indices.get(index: index_alias_name)
        rescue Elastic::Transport::Transport::Errors::NotFound
            {}
        end

        # Elasticsearch のalias存在確認APIを呼び出す。
        def indices_exists_alias(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.indices.exists_alias(name: index_alias_name)
        end

        # alias名と同名の物理indexが存在するか確認する。
        def alias_named_physical_index_exists?(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.indices.exists(index: index_alias_name)
        end

        # timestamp付き物理indexを削除する。
        def delete_physical_index(physical_index_name:)
            AreSearch::IndexDefinition.valid_physical_index_name!(physical_index_name)

            AreSearch.client.indices.delete(index: physical_index_name)

            return success
        rescue Elastic::Transport::Transport::Errors::NotFound
            return not_found
        end

        # alias名と同名の物理indexを削除する。
        def delete_alias_named_physical_index(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.indices.delete(index: index_alias_name)

            return success
        rescue Elastic::Transport::Transport::Errors::NotFound
            return not_found
        end

        # Elasticsearch のindex作成APIを呼び出す。
        def indices_create(physical_index_name:, body:)
            AreSearch::IndexDefinition.valid_physical_index_name!(physical_index_name)

            AreSearch.client.indices.create(
                index: physical_index_name,
                body:  body,
            )
        end

        # 旧物理indexから新物理indexへaliasを切り替える。
        # 物理index名を検査し、alias更新bodyを組み立ててElasticsearchへ送信する。
        #
        # acknowledged が true で errors が true ではない場合は success を返す。
        # errors が true の場合は not_success を返す。
        # 応答だけで成否を確定できない場合はaliasの接続先を確認して判定する。
        def update_alias(old_physical_index_names:, new_physical_index_name:)
            unless old_physical_index_names.instance_of?(Array)
                raise ArgumentError, "old_physical_index_names は Array で指定してください"
            end

            AreSearch::IndexDefinition.valid_physical_index_name!(new_physical_index_name)

            index_alias_name = AreSearch::IndexDefinition.index_alias_name_from_physical_index_name(new_physical_index_name)

            actions = []
            old_physical_index_names.each do |old_physical_index_name|
                AreSearch::IndexDefinition.valid_physical_index_name!(old_physical_index_name)

                old_index_alias_name = AreSearch::IndexDefinition.index_alias_name_from_physical_index_name(old_physical_index_name)

                unless old_index_alias_name == index_alias_name
                    raise ArgumentError, "old_physical_index_names と new_physical_index_name の alias 名が一致しません"
                end

                actions << { remove: { index: old_physical_index_name, alias: index_alias_name } }
            end

            actions << { add: { index: new_physical_index_name, alias: index_alias_name } }

            result = AreSearch.client.indices.update_aliases(body: { actions: actions })

            if result["acknowledged"] == true && result["errors"] != true
                return AreSearch::EsAdapter.success
            end

            if result["errors"] == true
                return AreSearch::EsAdapter.not_success
            end

            current_physical_names = indices_get_alias(index_alias_name: index_alias_name).keys

            if current_physical_names.length == 1 && current_physical_names.first == new_physical_index_name
                AreSearch::EsAdapter.success
            else
                AreSearch::EsAdapter.not_success
            end
        end
    end
end
