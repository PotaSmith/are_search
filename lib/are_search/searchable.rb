# frozen_string_literal: true

module AreSearch
    module Searchable
        extend ActiveSupport::Concern

        included do
            validate       :are_search_es_data_validate
            after_save     :are_search_enqueue_es_sync_request
            after_touch    :are_search_enqueue_es_sync_request
            after_destroy  :are_search_enqueue_es_sync_request
            after_commit   :are_search_after_commit
        end

        # 各モデルで必ず実装すること
        # 例:
        #
        #   def self.are_search_es_mappings
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
        #   def are_search_es_data(target_name)
        #       case target_name
        #       when :default
        #           {
        #               id:           id,
        #               user_id:      user_id,
        #               updated_at:   updated_at,
        #               title:        title&.gsub(/[^[:print:]]/, ' '),
        #               text_data:    text_data&.gsub(/[^[:print:]]/, ' '),
        #           }
        #       else
        #           {}
        #       end
        #   end
        #

        # Elasticsearch に index していいのかを判定する
        # 必要に応じてオーバーライドすること
        def are_search_es_indexable?(target_name)
            true
        end

        # Elasticsearch に投入する data を取得し、
        # AreSearch 予約フィールドが利用側 data に含まれていないことを確認する。
        # validate_es_data = false の場合でも、ES投入直前では必ずこの検査を通す。
        def are_search_es_data_for_index!(index_target)
            data = are_search_es_data(index_target.target_name)

            unless data.instance_of?(Hash)
                raise AreSearch::Error,
                    "#{self.class.name}#are_search_es_data(#{index_target.target_name.inspect}) は Hash を返してください"
            end

            reserved_data_field_names = AreSearch::EsDataValidator.reserved_data_field_names(data)

            unless reserved_data_field_names.empty?
                raise AreSearch::Error,
                    "#{self.class.name}#are_search_es_data(#{index_target.target_name.inspect}) に AreSearch の予約フィールドは指定できません: #{reserved_data_field_names.join(", ")}"
            end

            # 親クラス全部拾う
            model_class_names = []

            current_model_class = self.class
            while current_model_class
                if current_model_class.include?(AreSearch::Searchable)
                    model_class_names << current_model_class.name
                end

                current_model_class = current_model_class.superclass
            end

            data[AreSearch::RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME] = model_class_names
            data[AreSearch::RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME] = self.id.to_s

            data
        end

        # このレコードの現在の状態を Elasticsearch へ直接反映する。
        # destroyed? の場合は delete、それ以外の場合は index を実行する。
        #
        # sync_request・非同期同期（SyncJob）とは独立した低レベルコマンド。
        # バッチでデータ加工して強制的に更新する、といった用途を想定している。
        # delete 対象がすでに存在しない場合の NotFound は are_search_es_delete! 側で無視する。
        # それ以外の Elasticsearch クライアント例外はそのまま伝播させる。
        #
        # @return [Object, nil] Elasticsearch クライアントの戻り値。delete 対象が存在しない場合は nil。
        def are_search_es_sync!(index_target)
            if destroyed? || are_search_es_indexable?(index_target.target_name) != true
                index_target.are_search_es_delete!(id)
            else
                AreSearch.client.index(
                    index: index_target.are_search_es_index_name,
                    id:    id.to_s,
                    body:  are_search_es_data_for_index!(index_target),
                )
            end
        end

        # validate フック。
        # are_search_es_data と are_search_es_mappings の整合性をチェックし、
        # 不整合があれば save を止める。
        #
        # are_search_es_data の呼び出しは rescue しない。typo 等で例外が出た場合は
        # そのまま伝播させ、save を止めたうえでスタックトレースで原因を見せる。
        def are_search_es_data_validate
            self.class.are_search_index_targets.each do |index_target|
                next if are_search_es_indexable?(index_target.target_name) != true
                next unless AreSearch.validate_es_data

                mappings = index_target.are_search_es_mappings
                data     = are_search_es_data(index_target.target_name)

                violations = AreSearch::EsDataValidator.validate(mappings, data)

                if data.instance_of?(Hash)
                    reserved_data_field_names = AreSearch::EsDataValidator.reserved_data_field_names(data)

                    unless reserved_data_field_names.empty?
                        violations << "are_search_es_data(#{index_target.target_name.inspect}) に AreSearch の予約フィールドは指定できません: #{reserved_data_field_names}"
                    end
                end

                next if violations.empty?

                AreSearch.logger.debug { "[AreSearch] data/mappings 不整合 #{self.class.name} #{id || 'new'}: #{violations.inspect}" }

                errors.add(:base, "[#{self.class.model_name.human}] 検索データが不正です")
            end
        end

        # レコード保存・削除時にsync_requestを記録する
        def are_search_enqueue_es_sync_request
            AreSearch.logger.debug { "call are_search_enqueue_es_sync_request #{self.class.name} #{id}" }

            request_sequence = AreSearch::SyncRequest.next_request_sequence

            self.class.are_search_index_targets.each do |index_target|
                AreSearch::SyncRequest.upsert(
                    {
                        ar_model_class_name:  self.class.name,
                        index_target_name:    index_target.target_name,
                        ar_instance_key:      id.to_s,
                        es_index_name:        index_target.are_search_es_index_name,
                        request_sequence:     request_sequence,
                        request_sequence_at:  Time.zone.now,
                        retry_count:          0,
                        last_error:           nil,
                    },
                    unique_by: [:es_index_name, :ar_model_class_name, :ar_instance_key],
                )
            end
        end

        def are_search_after_commit
            self.class.are_search_index_targets.each do |index_target|
                case AreSearch.after_commit_mode
                when :job
                    are_search_enqueue_es_sync_job(index_target)
                when :direct
                    are_search_es_sync_direct(index_target)
                when :none
                    # 何もしない rake タスク任せ
                else
                    raise ArgumentError, "unknown after_commit_mode: #{AreSearch.after_commit_mode.inspect}"
                end
            end
        end

        # コミット確定時に同期ジョブをキューイングする
        def are_search_enqueue_es_sync_job(index_target)
            AreSearch.logger.debug { "call are_search_enqueue_es_sync_job #{self.class.name} #{id}" }

            AreSearch::SyncJob.perform_later(
                self.class.connection_db_config.database,
                self.class.name,
                index_target.target_name,
                id.to_s,
                index_target.are_search_es_index_name,
                SecureRandom.uuid,
            )
        end

        # コミット確定時に直接同期
        def are_search_es_sync_direct(index_target)
            ar_model_class_name = self.class.name
            target_name         = index_target.target_name
            ar_instance_key     = id.to_s
            es_index_name       = index_target.are_search_es_index_name
            processing_token    = SecureRandom.uuid

            AreSearch::RecordSync.sync(
                ar_model_class_name,
                target_name,
                ar_instance_key,
                es_index_name,
                processing_token,
                reraise: false
            )
        end

        class_methods do

            # Elasticsearch index 名に使用する Active Record 側の識別名を返す。
            # 既定では table_name を使用し、必要なモデルだけオーバーライドする。
            def are_search_ar_table_name
                table_name
            end

            # このモデルが持つ全 index target を返す。
            def are_search_index_targets
                return @are_search_index_targets unless @are_search_index_targets.nil?

                are_search_validate_es_mappings_by_target!

                target_names = are_search_es_mappings.keys
                targets = target_names.map { |target_name| AreSearch::IndexTarget.new(self, target_name) }

                @are_search_index_targets = targets.freeze
            end

            def are_search_index_target_map
                return @are_search_index_target_map unless @are_search_index_target_map.nil?

                target_map = {}

                are_search_index_targets.each do |index_target|
                    target_map[index_target.target_name] = index_target
                end

                @are_search_index_target_map = target_map.freeze
            end

            # 指定 target_name の index target を返す。
            def are_search_index_target(target_name)
                return nil if target_name.blank?

                are_search_index_target_map[target_name.to_sym]
            end


            # テスト用
            def are_search_reset_index_targets!
                @are_search_index_targets = nil
                @are_search_index_target_map = nil
            end

            def are_search_validate_es_mappings_by_target!
                errors = []

                are_search_ar_table_name_errors(errors)
                are_search_es_mappings_by_target_errors(errors)

                return true if errors.empty?

                raise ArgumentError, errors.join("\n")
            end

            def are_search_validate_model_setting(errors)
                are_search_ar_table_name_errors(errors)
                are_search_es_mappings_by_target_errors(errors)

                true
            rescue StandardError => e
                errors << "#{name} のモデル設定検査中に例外が発生しました: #{e.class}: #{e.message}"

                false
            end

            # Elasticsearch index 名に使用する識別名の形式を検査する。
            def are_search_ar_table_name_errors(errors)
                ar_table_name = are_search_ar_table_name

                unless AreSearch.valid_es_index_name_element?(ar_table_name)
                    errors << "#{name}.are_search_ar_table_name は小文字の英字で始まり、小文字の英字とアンダーバーだけを使用した String を返してください: #{ar_table_name.inspect}"
                end

                if ar_table_name.to_s.include?(AreSearch::ES_INDEX_NAME_DELIMITER)
                    errors << "#{name}.are_search_ar_table_name に " \
                        "#{AreSearch::ES_INDEX_NAME_DELIMITER.inspect} は使用できません: #{ar_table_name.inspect}"
                end

                errors
            end

            def are_search_es_mappings_by_target_errors(errors)
                mappings = are_search_es_mappings

                unless mappings.instance_of?(Hash)
                    errors << "#{name}.are_search_es_mappings は Hash を返してください"
                    return errors
                end

                if mappings.empty?
                    errors << "#{name}.are_search_es_mappings には1件以上の target を定義してください"
                    return errors
                end

                if mappings.key?(:properties)
                    errors << "#{name}.are_search_es_mappings のトップレベルに properties は指定できません。target_nameを指定してください"
                    return errors
                end

                if mappings.key?(:index_settings)
                    errors << "#{name}.are_search_es_mappings のトップレベルに index_settings は指定できません。target_nameを指定してください"
                    return errors
                end

                mappings.each do |target_name, target_mappings|
                    unless target_name.instance_of?(Symbol)
                        errors << "#{name}.are_search_es_mappings の target_name は Symbol で指定してください: #{target_name.inspect}"
                    end

                    target_name_string = target_name.to_s

                    unless AreSearch.valid_es_index_name_element?(target_name_string)
                        errors << "#{name}.are_search_es_mappings の target_name は小文字の英字で始まり、" \
                            "小文字の英字とアンダーバーだけを使用してください: #{target_name.inspect}"
                    end

                    if target_name_string.include?(AreSearch::ES_INDEX_NAME_DELIMITER)
                        errors << "#{name}.are_search_es_mappings の target_name に " \
                            "#{AreSearch::ES_INDEX_NAME_DELIMITER.inspect} は使用できません: #{target_name.inspect}"
                    end

                    unless target_mappings.instance_of?(Hash)
                        errors << "#{name}.are_search_es_mappings[#{target_name.inspect}] は Hash で指定してください"
                        next
                    end

                    unless target_mappings.key?(:index_settings)
                        errors << "#{name}.are_search_es_mappings[#{target_name.inspect}] に :index_settings がありません"
                    end

                    unless target_mappings.key?(:properties)
                        errors << "#{name}.are_search_es_mappings[#{target_name.inspect}] に :properties がありません"
                    end

                    if target_mappings.key?(:index_settings) && target_mappings[:index_settings].instance_of?(Hash) == false
                        errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:index_settings] は Hash で指定してください"
                    end

                    if target_mappings.key?(:index_settings) && target_mappings[:index_settings].instance_of?(Hash)
                        max_result_window = target_mappings[:index_settings][:max_result_window]

                        unless max_result_window.instance_of?(Integer) && max_result_window > 0
                            errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:index_settings][:max_result_window] は正の整数で指定してください"
                        end
                    end

                    if target_mappings.key?(:_source)
                        source_settings = target_mappings[:_source]

                        if source_settings.instance_of?(Hash) == false
                            errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:_source] は Hash で指定してください"
                        elsif source_settings[:enabled] == false
                            errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:_source][:enabled] に false は指定できません"
                        end
                    end

                    if target_mappings.key?(:properties) && target_mappings[:properties].instance_of?(Hash) == false
                        errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:properties] は Hash で指定してください"
                    end

                    if target_mappings.key?(:properties) && target_mappings[:properties].instance_of?(Hash)
                        reserved_data_field_names = AreSearch::EsDataValidator.reserved_data_field_names(target_mappings[:properties])

                        reserved_data_field_names.each do |reserved_field_name|
                            errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:properties] に AreSearch の予約フィールドは指定できません: #{reserved_field_name}"
                        end

                        target_mappings[:properties].each_key do |field_name|
                            if AreSearch.es_search_body_policy.invalid_key?(field_name)
                                errors << "#{name}.are_search_es_mappings[#{target_name.inspect}][:properties] に検索body policyで許可されていないフィールド名は指定できません: #{field_name}"
                            end
                        end
                    end

                    violations = AreSearch::EsDataValidator.validate_mapping_symbol_keys(target_mappings)

                    violations.each do |violation|
                        errors << "#{name}.are_search_es_mappings[#{target_name.inspect}] #{violation}"
                    end
                end

                errors
            end
        end
    end
end
