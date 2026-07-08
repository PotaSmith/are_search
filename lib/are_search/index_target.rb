# frozen_string_literal: true

module AreSearch
    class IndexTarget
        attr_reader :model_class, :target_name

        def initialize(model_class, target_name = :default)
            raise ArgumentError, "model_class が必要です" if model_class.nil?
            raise ArgumentError, "target name が必要です" if target_name.nil?

            @model_class = model_class
            @target_name = target_name.to_sym
        end

        # alias名: {prefix}_{table_name}
        # 検索・index・delete・sync 等、既存の呼び出し元はこの名前を参照する。
        # prefix は config/initializers/are_search.rb で設定。
        def are_search_es_index_name
            [AreSearch.index_prefix, model_class.table_name, target_name].compact.join("_")
        end

        # index作成時の index settings
        def are_search_es_index_settings
            target_mappings[:index_settings]
        end

        # Elasticsearch に渡す mappings
        def are_search_es_mappings
            mappings = {}

            target_mappings.each do |key, value|
                next if key == :index_settings

                mappings[key] = value
            end

            mappings
        end

        # 初期index作成中、reindex 処理中、または異常終了の痕跡があるかを返す。
        def are_search_es_index_marked?
            AreSearch::IndexMarker.marked?(are_search_es_index_name)
        end

        # alias が指していない古い物理インデックスをすべて削除する（currentのみ残す）。
        def are_search_es_clean_up
            AreSearch::IndexManager.es_clean_up(are_search_es_index_name)
        end

        # 検索結果復元用のcomposite_keyを生成する
        def are_search_es_composite_key(id)
            "#{are_search_es_index_name}/#{id}"
        end

        # 全件をElasticsearchに投入する（移行時・スキーマ変更時に実行する）。
        #
        # flock とマーカーファイルの管理は IndexManager.es_reindex に委ね、
        # その内側で create とバッチ投入を実行する。
        #
        # es_reindex は別プロセスが実行中で flock を取得できなかった場合に false を返す。
        #
        # es_reindex の内側（flock 取得済み・マーカーファイル作成済み）で
        # 新しい physical index を作成し、その physical index へ bulk 投入する。
        # block が正常終了した場合のみ IndexManager 側で alias を切り替える。
        #
        # @return [Array<String>, false]
        #   Array<String> : インデックス失敗した ID の配列。空なら全件成功。
        #   false         : 別プロセスが reindex 実行中で、今回は未実行。
        def are_search_es_reindex
            AreSearch::Reindexer.reindex_index_target(self)
        end

        # 検索を実行する
        #
        # AreSearch::SingleSearch.search のラッパー。
        # オプションの仕様は SingleSearch.search を参照。
        #
        # @return [SearchResult]
        #
        def are_search_es_search(query, **options)
            AreSearch::SingleSearch.search(self, query, **options)
        end

        # 指定した ar_instance_key のドキュメントをElasticsearchから強制的にdeleteする。
        #
        # sync_request・非同期同期（SyncJob）とは独立した低レベルコマンド。
        # バッチでデータ加工して強制的に更新する、といった用途を想定している。
        # Elasticsearchクライアントの例外はそのまま伝播させる。
        #
        # @param ar_instance_key [Object] 削除対象のid
        # @return [Object] Elasticsearchクライアントの戻り値
        def are_search_es_delete!(ar_instance_key)
            AreSearch.client.delete(
                index: are_search_es_index_name,
                id:    ar_instance_key.to_s,
            )
        rescue Elastic::Transport::Transport::Errors::NotFound
            # すでに存在しない場合は無視
        end

        # sync_request 1件分の同期を実行する
        #
        # 先頭で reindex 中かを確認し、reindex 中であれば同期をスキップする。
        # スキップ時は外から見ると成功扱い（例外を出さず正常 return）。
        # SyncRequest は消えず、last_error に reindex 中である旨を記録する。
        # retry_count は増やさない。
        #
        # reindex 中でない場合は DBから ar_instance_key で再取得し、
        # 存在すればindex、存在しなければdeleteする。
        # 成功時はsync_requestを削除し、失敗時はretry_count・last_errorを更新する。
        #
        # reraise: true の場合、失敗時にretry_count・last_errorを更新した上で
        # 例外を呼び出し元へ再送出する。SyncJob から retry_on を効かせるために使う。
        # reraise: false（デフォルト）の場合は例外を握りつぶす。rake タスクの
        # run_sync_requests は1件の失敗で全体を止めないため、こちらを使う。
        #
        def are_search_es_sync(ar_instance_key, reraise: false)
            AreSearch::RecordSync.sync(model_class.name, target_name, ar_instance_key, are_search_es_index_name, SecureRandom.uuid, reraise: reraise)
        end

        private

        def target_mappings
            model_class.are_search_es_mappings[target_name]
        end
    end
end


