# frozen_string_literal: true

module AreSearch
    module Searchable
        extend ActiveSupport::Concern

        included do
            after_save     :are_search_enqueue_sync_request
            after_touch    :are_search_enqueue_sync_request
            after_destroy  :are_search_enqueue_sync_request
            after_commit   :are_search_after_commit
        end

        # 各モデルで必ず実装すること
        # 例:
        #
        #   def self.are_search_index_mappings
        #       {
        #           default: {
        #              index_settings: {
        #                  max_result_window: 2_000,
        #              },
        #              properties: {
        #                  name:        { type: 'text',    analyzer: 'cjk_index_analyzer', search_analyzer: 'cjk_search_analyzer' },
        #                  documents:   { type: 'text',    analyzer: 'cjk_index_analyzer', search_analyzer: 'cjk_search_analyzer', store: true },
        #                  status:      { type: 'keyword' },
        #              }
        #           }
        #       }
        #   end
        #
        #   def are_search_index_data(index_target_name, sync_stage_name)
        #       case [index_target_name, sync_stage_name]
        #       when [:default, "default"]
        #           {
        #               id:           id,
        #               user_id:      user_id,
        #               updated_at:   updated_at,
        #               title:        title&.gsub(/[^[:print:]]/, ' '),
        #               text_data:    text_data&.gsub(/[^[:print:]]/, ' '),
        #               fulltext:     '',
        #           }
        #       when [:default, "with_external_file"]
        #           {
        #               id:           id,
        #               user_id:      user_id,
        #               updated_at:   updated_at,
        #               title:        title&.gsub(/[^[:print:]]/, ' '),
        #               text_data:    text_data&.gsub(/[^[:print:]]/, ' '),
        #               fulltext:     get_huge_file_txt,
        #           }
        #       else
        #           {}
        #       end
        #   end
        #
        #   この3つは整合性がチェックされる
        #   are_search_index_mappings に存在しない index_target_name は指定できない
        #   on_enqueue は all の部分集合、on_after_commit は on_enqueue の部分集合とする
        #
        #   def self.are_search_all_sync_stage_names
        #       {
        #           default: ["default", "with_external_file"],
        #       }
        #   end
        #
        #   def self.are_search_sync_stage_names_on_enqueue
        #       {
        #           default: ["default"],
        #       }
        #   end
        #
        #   def self.are_search_sync_stage_names_on_after_commit
        #       {
        #           default: ["default"],
        #       }
        #   end
        #
        #   def self.are_search_before_sync_check(ar_instance_key, index_target, sync_request)
        #       if sync_request.sync_stage_name == "with_external_file"
        #           前のステージが残ってるならやらない
        #           are_search_sync_request_exists?(ar_instance_key, index_target, "default") == false
        #       else
        #           true
        #       end
        #   end
        #
        #   def self.are_search_after_sync_callback(record, index_target, sync_request)
        #       if sync_request.sync_stage_name == "default" && record.nil? == false
        #           次のステージに進める
        #           record.are_search_upsert_sync_request(index_target, "with_external_file")
        #       end
        #   end
        #


        # 削除フラグ運用対応
        # Elasticsearch に index していいのかを判定する
        # 必要に応じてオーバーライドすること
        def are_search_indexable?(index_target_name, sync_stage_name)
            true
        end

        # Elasticsearch に投入する data を取得し、
        # AreSearch 予約フィールドが利用側 data に含まれていないことを確認する。
        def are_search_index_data_for_index!(index_target, sync_stage_name)
            data = are_search_index_data(index_target.index_target_name, sync_stage_name)

            unless data.instance_of?(Hash)
                raise AreSearch::Error,
                    "#{self.class.name}#are_search_index_data(" \
                        "#{index_target.index_target_name.inspect}, #{sync_stage_name.inspect}) は Hash を返してください"
            end

            reserved_index_field_names = AreSearch::IndexDataValidator.find_reserved_index_field_names(data)

            unless reserved_index_field_names.empty?
                raise AreSearch::Error,
                    "#{self.class.name}#are_search_index_data(" \
                        "#{index_target.index_target_name.inspect}, #{sync_stage_name.inspect}) に " \
                        "AreSearch の予約フィールドは指定できません: " \
                        "#{reserved_index_field_names.join(", ")}"
            end

            # 利用側が返した Hash を変更せず、AreSearch の予約フィールドは複製側へ追加する。
            data_for_index = data.dup

            # 親クラス全部拾う
            model_class_names = []

            current_model_class = self.class
            while current_model_class
                if current_model_class.include?(AreSearch::Searchable)
                    model_class_names << current_model_class.name
                end

                current_model_class = current_model_class.superclass
            end

            data_for_index[AreSearch::IndexDefinition::RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME] = model_class_names
            data_for_index[AreSearch::IndexDefinition::RESERVED_AR_INSTANCE_KEY_FIELD_NAME] = self.id.to_s

            data_for_index
        end

        # このレコードの現在の状態を Elasticsearch へ直接反映する。
        # destroyed? の場合は delete、それ以外の場合は index を実行する。
        #
        # sync_request・非同期同期（SyncJob）とは独立した低レベルコマンド。
        # index marker と alias の存在は確認しない。
        # バッチでデータ加工して強制的に更新する、といった用途を想定している。
        # delete 対象がすでに存在しない場合の NotFound は are_search_delete! 側で無視する。
        # それ以外の Elasticsearch クライアント例外はそのまま伝播させる。
        #
        # @return [Object, nil] index時はElasticsearchクライアントの戻り値、delete時は nil。
        def are_search_index_or_delete!(index_target, sync_stage_name)
            if destroyed? || are_search_indexable?(index_target.index_target_name, sync_stage_name) != true
                index_target.are_search_delete!(id)
            else
                AreSearch::EsAdapter.index(
                    index_alias_name: index_target.are_search_index_alias_name,
                    id:               id.to_s,
                    body:             are_search_index_data_for_index!(index_target, sync_stage_name),
                )
            end
        end

        # ユーザデバッグよう
        # are_search_index_data と are_search_index_mappings の整合性をチェックし、
        # 不整合があればエラーをログとインスタンスのerrorsに追加
        #
        # are_search_index_data の呼び出しは rescue しない。
        # typo 等で例外が出るかどうかを確認するのが目的
        def are_search_index_data_validate
            self.class.are_search_index_targets.each do |index_target|
                self.class.are_search_get_all_sync_stage_names(index_target.index_target_name).each do |sync_stage_name|
                    next if are_search_indexable?(index_target.index_target_name, sync_stage_name) != true

                    mappings = index_target.are_search_index_mappings
                    data     = are_search_index_data(index_target.index_target_name, sync_stage_name)

                    violations = AreSearch::IndexDataValidator.validate(mappings, data)

                    if data.instance_of?(Hash)
                        reserved_index_field_names = AreSearch::IndexDataValidator.find_reserved_index_field_names(data)

                        unless reserved_index_field_names.empty?
                            violations << "are_search_index_data(#{index_target.index_target_name.inspect}, #{sync_stage_name.inspect}) に AreSearch の予約フィールドは指定できません: #{reserved_index_field_names}"
                        end
                    end

                    next if violations.empty?

                    AreSearch.logger.debug { "[AreSearch] data/mappings 不整合 #{self.class.name} #{id || 'new'}: #{violations.inspect}" }

                    errors.add(:base, "[#{self.class.model_name.human}] 検索データが不正です")
                end
            end
        end

        # レコード保存・削除時にsync_requestを記録する
        def are_search_enqueue_sync_request
            AreSearch.logger.debug { "call are_search_enqueue_sync_request #{self.class.name} #{id}" }

            request_sequence = AreSearch.database_specific.next_request_sequence
            request_sequence_at = Time.zone.now

            self.class.are_search_index_targets.each do |index_target|
                self.class.are_search_get_sync_stage_names_on_enqueue(index_target.index_target_name).each do |sync_stage_name|
                    are_search_upsert_sync_request_with_sequence(
                        index_target,
                        sync_stage_name,
                        request_sequence,
                        request_sequence_at,
                    )
                end
            end
        end
        def are_search_upsert_sync_request(index_target, sync_stage_name)
            request_sequence = AreSearch.database_specific.next_request_sequence
            request_sequence_at = Time.zone.now

            are_search_upsert_sync_request_with_sequence(index_target, sync_stage_name, request_sequence, request_sequence_at)
        end

        def are_search_upsert_sync_request_with_sequence(index_target, sync_stage_name, request_sequence, request_sequence_at)
            all_sync_stage_names = self.class.are_search_get_all_sync_stage_names(index_target.index_target_name)

            unless all_sync_stage_names.include?(sync_stage_name)
                raise ArgumentError,
                    "#{self.class.name}.are_search_all_sync_stage_names[#{index_target.index_target_name.inspect}] に存在しない stage が指定されています: #{sync_stage_name.inspect}"
            end

            AreSearch.database_specific.upsert(
                ar_model_class_name: self.class.name,
                ar_instance_key:     id.to_s,
                index_alias_name:    index_target.are_search_index_alias_name,
                sync_stage_name:     sync_stage_name,
                index_target_name:   index_target.index_target_name,
                request_sequence:    request_sequence,
                request_sequence_at: request_sequence_at,
            )
        end

        def are_search_after_commit
            self.class.are_search_index_targets.each do |index_target|
                self.class.are_search_get_sync_stage_names_on_after_commit(index_target.index_target_name).each do |sync_stage_name|
                    case AreSearch.after_commit_mode
                    when :job
                        are_search_enqueue_sync_job(index_target, sync_stage_name)
                    when :direct
                        index_target.are_search_sync(id, sync_stage_name)
                    when :none
                        # 何もしない rake タスク任せ
                    else
                        raise ArgumentError, "unknown after_commit_mode: #{AreSearch.after_commit_mode.inspect}"
                    end
                end
            end
        end

        # コミット確定時に同期ジョブをキューイングする
        def are_search_enqueue_sync_job(index_target, sync_stage_name)
            AreSearch.logger.debug { "call are_search_enqueue_sync_job #{self.class.name} #{id}" }

            AreSearch::SyncJob.perform_later(
                self.class.connection_db_config.database,
                self.class.name,
                id.to_s,
                index_target.are_search_index_alias_name,
                sync_stage_name,
                SecureRandom.uuid,
            )
        end

        class_methods do

            # Elasticsearch index 名に使用する Active Record 側の識別名を返す。
            # 既定では table_name を使用し、必要なモデルだけオーバーライドする。
            def are_search_ar_table_name
                table_name
            end

            # 省略時は全対象
            def are_search_sync_stage_names_on_enqueue
                are_search_all_sync_stage_names
            end

            # 省略時は全対象
            def are_search_sync_stage_names_on_after_commit
                are_search_all_sync_stage_names
            end

            def are_search_before_sync_check(ar_instance_key, index_target, sync_request)
                # オーバーライド前提
                true
            end

            def are_search_after_sync_callback(record, index_target, sync_request)
                # オーバーライド前提
            end

            # これは、ここでやることではないけど、使い勝手的にここが楽
            def are_search_sync_request_exists?(ar_instance_key, index_target, sync_stage_name)
                AreSearch::SyncRequest.where(
                    ar_model_class_name: self.name,
                    ar_instance_key:     ar_instance_key.to_s,
                    index_alias_name:    index_target.are_search_index_alias_name,
                    sync_stage_name:     sync_stage_name,
                ).exists?
            end

            # このモデルが持つ全 index target を返す。
            def are_search_index_targets
                return @are_search_index_targets unless @are_search_index_targets.nil?

                definition_errors = []
                AreSearch::SearchableValidator.validate(self, definition_errors)

                if definition_errors.empty? == false
                    raise ArgumentError, definition_errors.join("\n")
                end

                index_target_names = are_search_index_mappings.keys
                targets = index_target_names.map { |index_target_name| AreSearch::IndexTarget.new(self, index_target_name) }

                @are_search_index_targets = targets.freeze
            end

            def are_search_index_target_map
                return @are_search_index_target_map unless @are_search_index_target_map.nil?

                target_map = {}

                are_search_index_targets.each do |index_target|
                    target_map[index_target.index_target_name] = index_target
                end

                @are_search_index_target_map = target_map.freeze
            end

            # 指定 index_target_name の index target を返す。
            def are_search_index_target(index_target_name)
                return nil if index_target_name.blank?

                are_search_index_target_map[index_target_name.to_sym]
            end

            # 指定 target に定義された全stageを、実行順のまま返す。
            def are_search_get_all_sync_stage_names(index_target_name)
                sync_stage_names = are_search_all_sync_stage_names[index_target_name]

                return [] if sync_stage_names.nil?

                sync_stage_names
            end

            # 指定 target で保存時に要求を作るstageを返す。
            def are_search_get_sync_stage_names_on_enqueue(index_target_name)
                sync_stage_names = are_search_sync_stage_names_on_enqueue[index_target_name]

                return [] if sync_stage_names.nil?

                sync_stage_names

            end

            def are_search_get_sync_stage_names_on_after_commit(index_target_name)
                sync_stage_names = are_search_sync_stage_names_on_after_commit[index_target_name]

                return [] if sync_stage_names.nil?

                sync_stage_names
            end

            # テスト用
            def are_search_reset_index_targets!
                @are_search_index_targets = nil
                @are_search_index_target_map = nil
            end

        end
    end
end
