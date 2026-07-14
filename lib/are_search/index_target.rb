# frozen_string_literal: true

module AreSearch
    class IndexTarget
        attr_reader :model_class, :target_name

        # モデルと target_name を保持し、index 名に使用できない値を拒否する。
        def initialize(model_class, target_name = :default)
            raise ArgumentError, "model_class が必要です" if model_class.nil?
            raise ArgumentError, "target name が必要です" if target_name.nil?

            ar_table_name = model_class.are_search_ar_table_name
            unless AreSearch.valid_es_index_name_element?(ar_table_name)
                raise ArgumentError,
                    "are_search_ar_table_name は小文字の英字で始まり、小文字の英字とアンダーバーだけを使用した String を返してください: #{ar_table_name.inspect}"
            end

            if ar_table_name.include?(AreSearch::ES_INDEX_NAME_DELIMITER)
                raise ArgumentError,
                    "are_search_ar_table_name に #{AreSearch::ES_INDEX_NAME_DELIMITER.inspect} は使用できません"
            end

            target_name_string = target_name.to_s
            unless AreSearch.valid_es_index_name_element?(target_name_string)
                raise ArgumentError,
                    "target name は小文字の英字で始まり、小文字の英字とアンダーバーだけを使用してください: #{target_name.inspect}"
            end

            if target_name_string.include?(AreSearch::ES_INDEX_NAME_DELIMITER)
                raise ArgumentError,
                    "target name に #{AreSearch::ES_INDEX_NAME_DELIMITER.inspect} は使用できません"
            end

            @model_class = model_class
            @target_name = target_name.to_sym
            @ar_table_name = ar_table_name
        end

        # alias名: {prefix}__{are_search_ar_table_name}__{target_name}
        # 検索・index・delete・sync 等、既存の呼び出し元はこの名前を参照する。
        # prefix は config/initializers/are_search.rb で設定。
        def are_search_es_index_name
            [
                AreSearch.index_prefix,
                @ar_table_name,
                target_name,
            ].join(AreSearch::ES_INDEX_NAME_DELIMITER)
        end

        # index作成時の index settings
        def are_search_es_index_settings
            target_mappings[:index_settings]
        end

        # ユーザが定義した are_search_es_mappings
        def are_search_es_mappings
            mappings = {}

            target_mappings.each do |key, value|
                next if key == :index_settings

                if key == :properties
                    if value.instance_of?(Hash)
                        new_properties = {}
                        value.each do |property_key, property_value|
                            new_properties[property_key] = property_value
                        end
                        mappings[key] = new_properties
                    else
                        # 事前チェックがあるから本来到達しないはず
                        raise ArgumentError, "properties が hashではありません。"
                    end
                else
                    mappings[key] = value
                end
            end

            mappings
        end

        # Elasticsearch に渡す mappings を作る。
        # 予約フィールドを properties と _source.includes に追加する。
        def are_search_es_mappings_for_index
            mappings = are_search_es_mappings

            return mappings unless mappings.key?(:properties)

            add_reserved_source_includes!(mappings)

            mappings[:properties][AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME] = AreSearch::RESERVED_ES_FIELD_NAME_SETTING
            mappings[:properties][AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME] = AreSearch::RESERVED_ES_FIELD_NAME_SETTING

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

        # 利用側の処理を、この index target の flock と marker でガードする。
        # block 内から are_search_es_sync! などの低レベル操作を実行する用途を想定する。
        def are_search_es_with_index_guard(operation:, &block)
            AreSearch::IndexManager.es_with_index_guard(
                are_search_es_index_name,
                operation: operation,
                &block
            )
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

        # 単一の index target を Searcher で検索する。
        # 指定された includes / results_where は、対象モデルを key にした
        # model_includes / model_results_where へ変換して渡す。
        #
        # @return [SearchResult]
        #
        def are_search_es_search(query, **options)
            invalid_options = []
            if options.key?(:model_includes)
                invalid_options << :model_includes
            end
            if options.key?(:model_results_where)
                invalid_options << :model_results_where
            end

            if invalid_options.any?
                raise ArgumentError,
                    "are_search_es_search に未知のオプションが指定されています: #{invalid_options.inspect}"
            end

            model = model_class
            index_targets = [self]

            includes_opt = options.delete(:includes)
            results_where_opt = options.delete(:results_where)

            if includes_opt.nil? == false
                options[:model_includes] = {
                    model => includes_opt,
                }
            end

            if results_where_opt.nil? == false
                options[:model_results_where] = {
                    model => results_where_opt,
                }
            end

            AreSearch::Searcher.search(
                index_targets,
                query_string: query,
                **options,
            )
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

        # 利用側の _source 設定をコピーし、予約フィールドを includes に追加する。
        # 元の are_search_es_mappings 定義は変更しない。
        def add_reserved_source_includes!(mappings)
            source_settings = {}

            if mappings.key?(:_source)
                source_settings = mappings[:_source].dup
            end

            source_includes = []
            configured_includes = source_settings[:includes]

            if configured_includes.instance_of?(Array)
                configured_includes.each do |field_name|
                    source_includes << field_name
                end
            elsif configured_includes.nil? == false
                source_includes << configured_includes
            end

            AreSearch::RESERVED_ES_FIELD_NAMES.each do |reserved_field_name|
                next if source_includes_field?(source_includes, reserved_field_name)

                source_includes << reserved_field_name
            end

            source_settings[:includes] = source_includes
            mappings[:_source] = source_settings
        end

        # Symbol / String の違いを無視して includes 内のフィールド重複を確認する。
        def source_includes_field?(source_includes, field_name)
            source_includes.each do |source_include|
                return true if source_include.to_s == field_name.to_s
            end

            false
        end

        def target_mappings
            model_class.are_search_es_mappings[target_name]
        end
    end
end
