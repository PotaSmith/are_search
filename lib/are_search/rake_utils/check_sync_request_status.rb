# frozen_string_literal: true

module AreSearch
    module RakeUtils
        module ArgCheck
            extend self

            # 処理対象にするSearchableモデルの一覧を作成する。
            def load_models
                Rails.application.eager_load!

                # このタスク内で処理対象にするSearchableモデルの一覧を作成する。
                ActiveRecord::Base.descendants.select do |klass|
                    klass.include?(AreSearch::Searchable)
                end
            end

            # 現在残っている sync lock を状態確認用の行データとして返す。
            def check_sync_stage_names(models, sync_stage_names)
                # 指定されたstageが、いずれかのSearchableモデルに定義されていることを確認する。
                defined_sync_stage_names = []

                models.each do |model|
                    model.are_search_index_targets.each do |index_target|
                        stage_names = index_target.are_search_sync_stage_names
                        defined_sync_stage_names.concat(stage_names)
                    end
                end

                undefined_sync_stage_names = sync_stage_names - defined_sync_stage_names

                if undefined_sync_stage_names.any?
                    raise ArgumentError, "定義されていない sync_stage_name があります: #{undefined_sync_stage_names.inspect}"
                end
            end
        end

        module CheckSyncRequestStatus
            extend self

            # 現在残っている sync lock を状態確認用の行データとして返す。
            def sync_lock_status_rows
                rows = []

                AreSearch::SyncLock.order(:index_alias_name, :id).each do |sync_lock|
                    started_at = ""
                    if sync_lock.started_at != nil
                        started_at = sync_lock.started_at.strftime("%Y-%m-%d %H:%M:%S")
                    end

                    rows << [
                        sync_lock.index_alias_name.to_s,
                        sync_lock.sync_stage_name.to_s,
                        sync_lock.operation.to_s,
                        started_at,
                        sync_lock.owner_host.to_s,
                        sync_lock.owner_pid.to_s,
                        sync_lock.message.to_s,
                    ]
                end

                rows
            end


            # sync request をモデル・IndexTarget・stage単位で集計し、総数・処理中数・エラー数を返す。
            def sync_request_status_rows
                total_counts = AreSearch::SyncRequest
                    .group(:ar_model_class_name, :index_target_name, :sync_stage_name)
                    .count

                processing_counts = AreSearch::SyncRequest
                    .where.not(processing_token: nil)
                    .group(:ar_model_class_name, :index_target_name, :sync_stage_name)
                    .count

                error_counts = AreSearch::SyncRequest
                    .where.not(last_error: [nil, ""])
                    .group(:ar_model_class_name, :index_target_name, :sync_stage_name)
                    .count

                rows = []

                total_counts.each do |group_values, data_count|
                    rows << [
                        group_values[0].to_s,
                        group_values[1].to_s,
                        group_values[2].to_s,
                        data_count.to_s,
                        processing_counts.fetch(group_values, 0).to_s,
                        error_counts.fetch(group_values, 0).to_s,
                    ]
                end

                rows.sort_by! { |row| [row[0], row[1], row[2]] }

                rows
            end

            # sync request のエラーをモデル・IndexTarget・stage・内容で集計し、件数上位を返す。
            def sync_request_error_status_rows(limit)
                error_counts = AreSearch::SyncRequest
                    .where.not(last_error: [nil, ""])
                    .group(:ar_model_class_name, :index_target_name, :sync_stage_name, :last_error)
                    .count

                rows = []

                error_counts.each do |group_values, count|
                    rows << [
                        group_values[0].to_s,
                        group_values[1].to_s,
                        group_values[2].to_s,
                        group_values[3].to_s,
                        count.to_s,
                    ]
                end

                rows.sort_by! do |row|
                    [-row[4].to_i, row[0], row[1], row[2], row[3]]
                end

                rows.first(limit)
            end

            # 各列の表示幅を揃えた文字列の行を返す。
            # 日本語を含む文字は端末上で2桁幅として扱う。
            def fixed_width_table_lines(headers, rows)
                all_rows = [headers]
                rows.each do |row|
                    all_rows << row
                end

                widths = Array.new(headers.length, 0)

                all_rows.each do |row|
                    row.each_with_index do |value, index|
                        value_width = terminal_display_width(value.to_s)
                        if value_width > widths[index]
                            widths[index] = value_width
                        end
                    end
                end

                lines = []

                all_rows.each do |row|
                    cells = []

                    row.each_with_index do |value, index|
                        cells << fixed_width_cell(value.to_s, widths[index])
                    end

                    lines << cells.join("  ").rstrip
                end

                lines
            end

            private

            # 端末表示上の文字幅を返す。
            # ASCII は1桁、それ以外は日本語表示を前提に2桁として数える。
            def terminal_display_width(value)
                width = 0

                value.each_char do |character|
                    if character.ascii_only?
                        width += 1
                    else
                        width += 2
                    end
                end

                width
            end

            # 指定された表示幅になるまで末尾へ空白を追加する。
            def fixed_width_cell(value, width)
                padding_size = width - terminal_display_width(value)

                value + (" " * padding_size)
            end
        end
    end
end
