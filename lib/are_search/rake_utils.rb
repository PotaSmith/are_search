# frozen_string_literal: true

module AreSearch
    module RakeUtils
        extend self

        def searchable_index_names
            Rails.application.eager_load!

            es_index_names = []

            ActiveRecord::Base.descendants.select { |klass| klass.include?(AreSearch::Searchable) }.each do |klass|
                klass.are_search_index_targets.each do |index_target|
                    es_index_name = index_target.are_search_es_index_name
                    next if es_index_names.include?(es_index_name)

                    es_index_names << es_index_name
                end
            end

            es_index_names
        end

        # 現在残っている index marker を状態確認用の行データとして返す。
        def index_marker_status_rows
            rows = []

            AreSearch::IndexMarker.order(:es_index_name, :id).each do |marker|
                started_at = ""
                if marker.started_at != nil
                    started_at = marker.started_at.strftime("%Y-%m-%d %H:%M:%S")
                end

                rows << [
                    marker.es_index_name.to_s,
                    marker.operation.to_s,
                    started_at,
                    marker.owner_host.to_s,
                    marker.owner_pid.to_s,
                    marker.message.to_s,
                ]
            end

            rows
        end

        # sync request をモデル単位で集計し、テーブル名・モデル名・総数・エラー数を返す。
        def sync_request_status_rows
            total_counts = AreSearch::SyncRequest
                .group(:ar_model_class_name)
                .count

            error_counts = AreSearch::SyncRequest
                .where.not(last_error: [nil, ""])
                .group(:ar_model_class_name)
                .count

            rows = []

            total_counts.each do |model_class_name, data_count|
                rows << [
                    sync_request_model_table_name(model_class_name),
                    model_class_name.to_s,
                    data_count.to_s,
                    error_counts.fetch(model_class_name, 0).to_s,
                ]
            end

            rows.sort_by! { |row| [row[0], row[1]] }

            rows
        end

        # sync request のエラーをテーブル名と内容で集計し、件数上位を返す。
        def sync_request_error_status_rows(limit)
            model_error_counts = AreSearch::SyncRequest
                .where.not(last_error: [nil, ""])
                .group(:ar_model_class_name, :last_error)
                .count

            table_error_counts = {}

            model_error_counts.each do |group_values, count|
                model_class_name = group_values[0]
                last_error = group_values[1]
                table_name = sync_request_model_table_name(model_class_name)
                table_error_key = [table_name, last_error.to_s]

                if table_error_counts.key?(table_error_key) == false
                    table_error_counts[table_error_key] = 0
                end

                table_error_counts[table_error_key] += count
            end

            rows = []

            table_error_counts.each do |table_error_key, count|
                rows << [
                    table_error_key[0],
                    table_error_key[1],
                    count.to_s,
                ]
            end

            rows.sort_by! do |row|
                [-row[2].to_i, row[0], row[1]]
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

        def model_check(klass, errors)
            puts "are_search_es_data method_defined : #{klass.method_defined?(:are_search_es_data)}"

            unless klass.method_defined?(:are_search_es_data)
                errors << "#{klass.name}: are_search_es_data が実装されていません。"
            end

            puts "are_search_es_mappings respond_to : #{klass.respond_to?(:are_search_es_mappings)}"

            searchable_from_superclass = klass.superclass&.include?(AreSearch::Searchable)
            declares_mappings_here = klass.singleton_class
                .public_instance_methods(false)
                .include?(:are_search_es_mappings)

            if searchable_from_superclass && declares_mappings_here
                errors << "#{klass.name}: are_search_es_mappings は Searchable を include した上位クラスで定義してください。"
            end

            return if searchable_from_superclass

            unless klass.respond_to?(:are_search_es_mappings)
                errors << "#{klass.name}: are_search_es_mappings が実装されていません。"
            end

            if klass.respond_to?(:are_search_es_mappings)
                klass.are_search_validate_model_setting(errors)
            end
        end

        def check_callback_order(errors)
            # Railsのコールバックチェーンの並び順が想定通りか検証する
            dummy_ar_class = Class.new(ActiveRecord::Base) do
                self.abstract_class = true
                after_save :aaa
                after_save :bbb
                after_save :ccc
            end
            dummy_ar_sub_class = Class.new(dummy_ar_class) do
                self.abstract_class = true
                after_save :ddd
                after_save :ccc
            end

            callbacks = dummy_ar_class._save_callbacks.select { |cb| cb.kind == :after }.map(&:filter)
            first_pattern = [:ccc, :bbb, :aaa]
            last_pattern  = [:aaa, :bbb, :ccc]
            unless [first_pattern, last_pattern].include?(callbacks)
                errors << "Railsのコールバック順序がなにやらおかしいです。" \
                          "想定: #{first_pattern.inspect} または #{last_pattern.inspect} 実際: #{callbacks.inspect}"
            end

            sub_callbacks = dummy_ar_sub_class._save_callbacks.select { |cb| cb.kind == :after }.map(&:filter)
            first_pattern_sub = [:ccc, :ddd, :bbb, :aaa]
            last_pattern_sub  = [:aaa, :bbb, :ddd, :ccc]
            unless [first_pattern_sub, last_pattern_sub].include?(sub_callbacks)
                errors << "Railsのコールバック順序がなにやらおかしいです（サブクラス）。" \
                          "想定: #{first_pattern_sub.inspect} または #{last_pattern_sub.inspect} 実際: #{sub_callbacks.inspect}"
            end
        end

        # 同じ Elasticsearch index 名が、独立した複数の Searchable 継承系統で
        # 使用されていないかを確認する。
        # STI の親子・兄弟モデルは同じ継承系統として扱い、同名 index を許可する。
        def validate_searchable_index_name_ownership(errors)
            searchable_models = all_searchable_include_models
            root_models = searchable_root_models(searchable_models)

            index_name_owners = {}

            searchable_models.each do |model|
                root_model = nil

                root_models.each do |candidate_model|
                    if model == candidate_model || model < candidate_model
                        root_model = candidate_model
                        break
                    end
                end

                model.are_search_index_targets.each do |index_target|
                    es_index_name = index_target.are_search_es_index_name
                    owner_model = index_name_owners[es_index_name]

                    if owner_model.nil?
                        index_name_owners[es_index_name] = root_model
                        next
                    end

                    next if owner_model == root_model

                    errors << "継承関係のないモデルが同じ index を使用しています: " \
                        "#{es_index_name}: #{owner_model.name}, #{root_model.name}"
                end
            end

            errors.empty?
        end

        # Searchable の全継承系統から、reindex を担当する最上位モデルの
        # index target だけを重複なく返す。
        def searchable_index_target_for_reindex
            # Searchable を直接 include したモデルだけでなく、
            # 継承によって Searchable になった子孫モデルもすべて取得する。
            searchable_models = all_searchable_include_models

            # STI では最上位モデルの relation に子孫モデルも含まれるため、
            # 各 Searchable 継承系統の最上位モデルだけを reindex 対象にする。
            # model < other_model は、直接の親だけでなく祖先全体を判定する。
            reindex_models = searchable_root_models(searchable_models)

            index_targets = []
            es_index_names = []

            # 独立した継承系統の最上位モデル同士で同じ index 名が使われていれば、
            # どちらを reindex 対象にするか決められないためエラーにする。
            reindex_models.each do |model|
                model.are_search_index_targets.each do |index_target|
                    es_index_name = index_target.are_search_es_index_name

                    if es_index_names.include?(es_index_name)
                        raise AreSearch::Error,
                            "[AreSearch] reindex 対象の index が複数の上位モデルで重複しています: #{es_index_name}"
                    end

                    es_index_names << es_index_name
                    index_targets << index_target
                end
            end

            index_targets
        end

        # Searchable モデルを継承系統ごとに整理し、
        # 各系統で最も上位にあるモデルだけを返す。
        def searchable_root_models(searchable_models)
            searchable_models.select do |model|
                is_upper_model(model, searchable_models)
            end
        end

        # modelsの中で最上位のモデルかを判定する
        def is_upper_model(model, models)
            models.each do |other_model|
                next if model == other_model

                # 上位モデルがある
                if model < other_model
                    return false
                end
            end

            return true
        end

        # Searchable を直接 include したモデルだけでなく、
        # 継承によって Searchable になった子孫モデルもすべて取得する。
        def all_searchable_include_models
            Rails.application.eager_load!

            ActiveRecord::Base.descendants.select do |model|
                model.include?(AreSearch::Searchable)
            end
        end

        private

        # sync request のモデル名からテーブル名を取得する。
        # モデルを解決できない場合はハイフンを返す。
        def sync_request_model_table_name(model_class_name)
            model = model_class_name.to_s.safe_constantize

            if model != nil && model.respond_to?(:table_name)
                return model.table_name.to_s
            end

            "-"
        end

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
