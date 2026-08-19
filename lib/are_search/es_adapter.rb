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
        def index(index_alias_name:, es_key:, body:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            response = AreSearch.client.index(index: index_alias_name, id: es_key, body: body)

            if response.respond_to?(:[]) == false || response["_id"] != es_key
                raise AreSearch::Error, "Elasticsearch index response の ID が一致しません"
            end

            if ["created", "updated"].include?(response["result"]) == false
                raise AreSearch::Error, "Elasticsearch index response の result が不正です: #{response["result"].inspect}"
            end

            response
        end

        # Elasticsearch の単一ドキュメント削除APIを呼び出す。
        def delete(index_alias_name:, es_key:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            response = AreSearch.client.delete(index: index_alias_name, id: es_key)

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
        # alias名と同名の物理indexだけが存在する場合、get_alias は NotFound になる。
        def indices_get_alias(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            response = AreSearch.client.indices.get_alias(name: index_alias_name)

            response.each_value do |index_info|
                aliases = index_info["aliases"]

                if aliases.instance_of?(Hash) == false || aliases.key?(index_alias_name) == false
                    raise AreSearch::Error, "Elasticsearch alias response に指定した alias がありません: #{index_alias_name}"
                end
            end

            response
        rescue Elastic::Transport::Transport::Errors::NotFound
            {}
        end

        # 指定aliasから生成されたtimestamp付き物理indexを取得する。
        # indices.get はaliasも解決するが、このメソッドは alias名 + "__*" の
        # AreSearch物理index形式だけを検索する。
        # 一致するindexが無い場合、Elasticsearch 9では成功した空responseが返る場合がある。
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
        # indices.get は通常aliasを参照先の物理indexへ解決するため、
        # 先にalias存在確認を行い、通常aliasは物理indexとして取得しない。
        def alias_named_physical_index(index_alias_name:)
            return {} if index_alias_exists?(index_alias_name: index_alias_name)

            AreSearch.client.indices.get(index: index_alias_name)
        rescue Elastic::Transport::Transport::Errors::NotFound
            {}
        end

        # Elasticsearch のaliasが存在するか確認する。
        # exists_alias の返り値はtrueの場合だけ存在として扱う。
        def index_alias_exists?(index_alias_name:)
            AreSearch::IndexDefinition.valid_index_alias_name!(index_alias_name)

            AreSearch.client.indices.exists_alias(name: index_alias_name) == true
        end

        # alias名と同名の物理indexが存在するか確認する。
        # indices.exists は通常aliasも存在扱いにするため、
        # 先にalias存在確認を行い、通常aliasは物理indexとして判定しない。
        def alias_named_physical_index_exists?(index_alias_name:)
            return false if index_alias_exists?(index_alias_name: index_alias_name)

            AreSearch.client.indices.exists(index: index_alias_name) == true
        end

        # timestamp付き物理indexを削除する。
        # indices.delete はaliasを参照先へ展開しない。
        # 物理index形式の名前を持つaliasを指定するとElasticsearchはBadRequestを返す。
        # NotFoundだけをnot_foundへ変換し、それ以外のElasticsearchエラーは送出する。
        def delete_physical_index(physical_index_name:)
            AreSearch::IndexDefinition.valid_physical_index_name!(physical_index_name)

            response = AreSearch.client.indices.delete(index: physical_index_name)

            if response.respond_to?(:[]) != true || response["acknowledged"] != true
                raise AreSearch::Error, "Elasticsearch index delete が acknowledge されませんでした"
            end

            success
        rescue Elastic::Transport::Transport::Errors::NotFound
            return not_found
        end

        # Elasticsearch のindex作成APIを呼び出す。
        # 同名のindexだけでなく、同名のaliasが存在する場合もElasticsearchはBadRequestを返す。
        def indices_create(physical_index_name:, body:)
            AreSearch::IndexDefinition.valid_physical_index_name!(physical_index_name)

            response = AreSearch.client.indices.create(index: physical_index_name, body: body)

            if response.respond_to?(:[]) != true || response["index"] != physical_index_name
                raise AreSearch::Error, "Elasticsearch index create response の index が一致しません"
            end

            if response["acknowledged"] != true
                raise AreSearch::Error, "Elasticsearch index create が acknowledge されませんでした"
            end

            if response["shards_acknowledged"] != true
                raise AreSearch::Error, "Elasticsearch index create の shard が acknowledge されませんでした"
            end

            response
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

                if old_index_alias_name != index_alias_name
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
