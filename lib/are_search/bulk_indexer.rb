# frozen_string_literal: true

module AreSearch
    class IndexTarget

        # このIndexTargetへ容量単位のbulk投入を実行する。
        def are_search_bulk_index(
            sync_stage_name,
            result_dir:,
            max_bulk_bytes:,
            max_bulk_count:,
            max_fail_count: 100,
            recover: false
        )
            bulk_indexer = AreSearch::BulkIndexer.new(
                self,
                sync_stage_name,
                result_dir: result_dir,
                max_bulk_bytes: max_bulk_bytes,
                max_bulk_count: max_bulk_count,
                max_fail_count: max_fail_count,
            )

            if recover == true
                bulk_indexer.bulk_recover_index_target
            else
                bulk_indexer.bulk_index_index_target
            end
        end
    end

    # 以下は直接呼ばない

    class BulkIndexer

        MAX_RECOVER_COUNT = 2000
        MAX_SKIP_COUNT = 1000

        # 1回のbulk投入で使用する対象と設定を保持する。
        def initialize(
            index_target,
            sync_stage_name,
            result_dir:,
            max_bulk_bytes:,
            max_bulk_count:,
            max_fail_count:
        )
            @index_target = index_target
            @sync_stage_name = sync_stage_name

            @result_dir = result_dir

            # validationをまとめる用
            @max_bulk_bytes = max_bulk_bytes
            @max_bulk_count = max_bulk_count
            @max_fail_count = max_fail_count

            @buffer = Buffer.new(
                max_bulk_bytes: @max_bulk_bytes,
                max_bulk_count: @max_bulk_count,
                max_fail_count: @max_fail_count,
                max_skip_count: MAX_SKIP_COUNT,
            )
        end

        # 実行条件を確認してbulk投入を開始する。
        def bulk_index_index_target
            validate_arguments!

            @data_dir = File.join(@result_dir, 'data')
            FileUtils.mkdir(@data_dir) if Dir.exist?(@data_dir) == false
            @recover_dir = File.join(@result_dir, 'recover')
            FileUtils.mkdir(@recover_dir) if Dir.exist?(@recover_dir) == false

            @logger = Logger.new(
                check_point_file_path:   File.join(@data_dir, 'check_point.log'),

                success_file_path:   File.join(@data_dir, 'bulk_success.log'),
                failure_file_path:   File.join(@data_dir, 'bulk_failure.log'),
                data_skip_file_path: File.join(@data_dir, 'data_skip.log'),
                data_fail_file_path: File.join(@data_dir, 'data_fail.log'),

                log_file_path:       File.join(@result_dir, 'bulk.log'),
            )

            recover_target_size = @logger.get_fail_key_uniq_size
            if (recover_target_size + 1) > @max_fail_count
                raise AreSearch::Error, "失敗が多すぎます。recoverを行ってください。#{recover_target_size}/#{@max_fail_count}"
            end

            @logger.set_fail_count

            relation = build_index_relation
            index_records(relation)

            last_key = @logger.get_last_check_point_key
            return "同期対象はありません。" if last_key.nil?

            fail_count = @logger.get_fail_key_uniq_size
            if fail_count == 0
                "id #{last_key} までの同期を終了しました。"
            else
                "id #{last_key} まで処理しました。recover対象 #{fail_count}件"
            end
        end

        # 実行条件を確認してbulk投入を開始する。
        def bulk_recover_index_target
            validate_arguments!

            @data_dir = File.join(@result_dir, 'data')
            FileUtils.mkdir(@data_dir) if Dir.exist?(@data_dir) == false
            @recover_dir = File.join(@result_dir, 'recover')
            FileUtils.mkdir(@recover_dir) if Dir.exist?(@recover_dir) == false

            @bulk_failure_target_file = File.join(@data_dir, 'bulk_failure.log')
            @data_fail_target_file    = File.join(@data_dir, 'data_fail.log')

            @logger = Logger.new(
                check_point_file_path:   nil,

                success_file_path:   File.join(@recover_dir, 'recover_bulk_success.log'),
                failure_file_path:   File.join(@recover_dir, 'recover_bulk_failure.log'),
                data_skip_file_path: File.join(@recover_dir, 'recover_data_skip.log'),
                data_fail_file_path: File.join(@recover_dir, 'recover_data_fail.log'),

                log_file_path:       File.join(@result_dir, 'bulk.log'),
            )

            if get_recover_keys.empty?
                if get_recover_target_keys.size > 0
                    @logger.rename_all([@bulk_failure_target_file, @data_fail_target_file])
                    return "recover対象がありません。終了処理が未処理であったため実施しました。"
                else
                    return "recover対象がありません"
                end
            end

            relation = build_recover_relation
            index_records(relation)

            if get_recover_keys.empty?
                @logger.rename_all([@bulk_failure_target_file, @data_fail_target_file])

                "recoverが完了しました。"
            else
                "recover対象が残っています。"
            end
        end

        private

        # BulkIndexerが使用する対象と実行設定を確認する。
        def validate_arguments!
            if @index_target.instance_of?(AreSearch::IndexTarget) == false
                raise ArgumentError, "index_target は AreSearch::IndexTarget を指定してください"
            end

            model_class = @index_target.model_class

            # 同じ alias を共有する上位モデルの全レコードを欠落させないため、
            # Searchable を継承した子クラスの IndexTarget を拒否する。
            if model_class.superclass&.include?(AreSearch::Searchable)
                raise AreSearch::Error,
                    "Searchable を継承した子クラスから bulk_index は実行できません: #{model_class.name}"
            end

            sync_stage_names = @index_target.are_search_sync_stage_names
            if sync_stage_names.include?(@sync_stage_name) == false
                raise ArgumentError,
                    "sync_stage_name が IndexTarget に定義されていません: #{@sync_stage_name}"
            end

            if @result_dir.instance_of?(String) == false || @result_dir.empty?
                raise ArgumentError, "result_dir を指定してください"
            end
            if Dir.exist?(@result_dir) == false
                raise ArgumentError, "result_dir がありません"
            end

            if @max_bulk_bytes.instance_of?(Integer) == false || @max_bulk_bytes <= 0
                raise ArgumentError, "max_bulk_bytes は正の Integer を指定してください"
            end

            if @max_bulk_count.instance_of?(Integer) == false || @max_bulk_count <= 0
                raise ArgumentError, "max_bulk_count は正の Integer を指定してください"
            end

            if @max_fail_count.instance_of?(Integer) == false || @max_fail_count <= 0
                raise ArgumentError, "max_fail_count は正の Integer を指定してください"
            end

            if @max_fail_count.instance_of?(Integer) && @max_fail_count > (MAX_RECOVER_COUNT / 2)
                raise ArgumentError, "max_fail_count は #{MAX_RECOVER_COUNT / 2} 以下で指定してください"
            end

            if @max_bulk_count > @max_fail_count
                raise ArgumentError, "max_bulk_count は max_fail_count 以下で指定してください"
            end

            if @index_target.are_search_index_alias_exists? == false
                raise ArgumentError,
                    "indexが存在しません #{@index_target.are_search_index_alias_name}"
            end
        end

        # 通常実行時はcheckpointが無ければ全件、あれば最後のcheckpoint IDより後を対象にする。
        def build_index_relation
            model_class = @index_target.model_class

            last_key = @logger.get_last_check_point_key
            return model_class.unscoped if last_key.nil?

            model_class.unscoped.where("id > ?", last_key)
        end

        # recover時は未解決の失敗IDを対象にし、DBに存在しないIDはdata_skipとして記録する。
        def build_recover_relation
            model_class = @index_target.model_class

            recover_keys = get_recover_keys

            existing_keys = model_class.unscoped.where(id: recover_keys).pluck(:id).map(&:to_s)

            missing_keys = recover_keys - existing_keys

            missing_keys.each do |key|
                # DBから削除済みの場合はrecover対象外。削除同期はSyncRequest/Boundary側の責務
                @logger.write_data_skip_result!(key)
            end

            model_class.unscoped.where(id: existing_keys)
        end

        # relationを1件ずつ処理し、容量上限を超えた時点でbulk送信する。
        def index_records(relation)
            relation.find_each do |record|
                key = record.id.to_s
                if @logger.invalid_key?(key)
                    raise AreSearch::Error,
                        "bulk結果ファイルへ記録できないIDです: #{key.inspect}"
                end

                append_buffer(record)

                if @buffer.capacity_over?(@logger)
                    send_bulk(@buffer.take)
                end

                @buffer.check_bulk_exit!(@logger)
            end

            send_bulk(@buffer.take_all)
        end

        # 対象レコードからbulkのactionとdataを作り、bufferへ渡す。
        # skip対象はactionとdataを持たない1件としてbufferへ渡す。
        def append_buffer(record)
            key = record.id.to_s

            if @index_target.are_search_indexable?(record) != false
                action = {
                    index: {
                        _index: @index_target.are_search_index_alias_name,
                        _id:    key,
                    },
                }
                data = record.are_search_index_data_for_index!(@index_target, @sync_stage_name)
            else
                action = {
                    delete: {
                        _index: @index_target.are_search_index_alias_name,
                        _id:    key,
                    },
                }
                data = nil
            end
            @buffer.append_sync_data(key, action, data)

        rescue StandardError => error
            @buffer.append_no_sync_data(key, :fail, error)
        end

        # 指定されたbulk bodyをElasticsearchへ送り、各IDの成否とエラー内容を記録する。
        # 投入対象が無い場合は送信を行わず、skipの記録だけを行う。
        def send_bulk(bulk_data)
            return if bulk_data.nil?

            if bulk_data[:keys].empty? == false
                response = AreSearch::EsAdapter.no_validation_bulk(body: bulk_data[:body])

                validate_bulk_response!(response, bulk_data[:keys])

                response["items"].each do |item|
                    result = item["index"] || item["delete"]

                    if result["error"].nil? == false
                        @logger.write_failure_result!(result["_id"], result["error"])
                    else
                        @logger.write_success_result!(result["_id"])
                    end
                end
            end

            bulk_data[:fail_key_and_errors].each do |key, error|
                @logger.write_data_fail_result!(key, error)
            end
            bulk_data[:skip_keys].each do |key|
                @logger.write_data_skip_result!(key)
            end

            @logger.write_check_point!(bulk_data[:check_point_key])
        end

        # bulk response が送信したIDと1対1で対応していることを確認する。
        def validate_bulk_response!(response, expected_keys)
            unless response.respond_to?(:[])
                raise AreSearch::Error, "Elasticsearch bulk response が不正です"
            end

            items = response["items"]
            unless items.instance_of?(Array)
                raise AreSearch::Error, "Elasticsearch bulk response の items が不正です"
            end

            if items.length != expected_keys.length
                raise AreSearch::Error,
                    "Elasticsearch bulk response の件数が一致しません"
            end

            items.each_with_index do |item, index|
                unless item.instance_of?(Hash)
                    raise AreSearch::Error, "Elasticsearch bulk response の item が不正です"
                end

                result = item["index"] || item["delete"]
                unless result.instance_of?(Hash)
                    raise AreSearch::Error, "Elasticsearch bulk response の index 結果が不正です"
                end

                if result["_id"] != expected_keys[index]
                    raise AreSearch::Error,
                        "Elasticsearch bulk response の ID が一致しません"
                end
            end
        end

        # 前回の失敗IDから、今回の結果ファイルに記録済みのIDを除いたものを対象にする。
        def get_recover_keys
            target_keys = get_recover_target_keys

            if target_keys.length > MAX_RECOVER_COUNT
                raise AreSearch::Error, "recover対象が多すぎます: #{target_keys.length} / 上限 #{MAX_RECOVER_COUNT}"
            end

            recover_keys = target_keys - @logger.get_not_fail_keys

            recover_keys
        end

        def get_recover_target_keys
            failure_keys = @logger.read_result_keys(@bulk_failure_target_file, Logger::FAILURE_RESULT)
            data_fail_keys = @logger.read_result_keys(@data_fail_target_file,  Logger::DATA_FAIL_RESULT)

            (failure_keys + data_fail_keys).uniq
        end

        class Buffer

            def initialize(max_bulk_bytes:, max_bulk_count:, max_fail_count:, max_skip_count:)
                @check_point_key = nil

                @keys = []
                @values = []
                @values_bytesize = 0
                @values_count = 0

                @reserved_key = nil
                @reserved_es_action = nil
                @reserved_index_data = nil
                @reserved_bytesize = 0

                @skip_keys = []
                @fail_key_and_errors = []

                @max_bulk_bytes = max_bulk_bytes
                @max_bulk_count = max_bulk_count
                @max_fail_count = max_fail_count
                @max_skip_count = max_skip_count
            end

            # 保留中の1件分を送信待ちへ移し、新しいfailまたはskipの1件分を保持する。
            def append_no_sync_data(key, action, data)
                unless [:fail, :skip].include?(action)
                    raise AreSearch::Error, "不正な内部操作です"
                end

                push_reserved

                @reserved_key = key
                @reserved_es_action = action
                @reserved_index_data = data
                @reserved_bytesize = 0
            end

            # 保留中の1件分を送信待ちへ移し、新しいindex/deleteの1件分をシリアライズして保持する。
            def append_sync_data(key, action, data)
                if [:fail, :skip].include?(action)
                    raise AreSearch::Error, "不正な内部操作です"
                end

                begin
                    if data.nil?
                        reserved_es_action = Elasticsearch::API.serializer.dump(action) + "\n"
                        reserved_bytesize = reserved_es_action.bytesize
                    else
                        reserved_es_action = Elasticsearch::API.serializer.dump(action) + "\n"
                        reserved_index_data = Elasticsearch::API.serializer.dump(data) + "\n"
                        reserved_bytesize = reserved_es_action.bytesize + reserved_index_data.bytesize
                    end
                rescue StandardError => error
                    append_no_sync_data(key, :fail, error)
                    return
                end

                if reserved_bytesize > @max_bulk_bytes
                    error = AreSearch::Error.new("max_bulk_bytes を超えるデータがあります: id #{key} size #{reserved_bytesize} / #{@max_bulk_bytes}")
                    append_no_sync_data(key, :fail, error)
                    return
                end

                push_reserved

                @reserved_key = key
                @reserved_es_action = reserved_es_action
                @reserved_index_data = reserved_index_data
                @reserved_bytesize = reserved_bytesize
            end

            def capacity_over?(logger)
                # データ量オーバー
                return true if total_data_size > @max_bulk_bytes
                return true if count >= @max_bulk_count

                # 送信待ちが多すぎる場合
                return true if @skip_keys.length >= @max_skip_count
                return true if @fail_key_and_errors.length >= @max_skip_count

                # 現在の失敗と、このbulkが全件失敗した場合の合計がrecover上限に達する場合
                possible_fail_count = logger.fail_count + @values_count + @fail_key_and_errors.length
                return true if possible_fail_count >= @max_fail_count

                # 失敗が多すぎる場合
                return true if logger.fail_count > @max_fail_count

                false
            end

            def check_bulk_exit!(logger)
                if logger.fail_count > @max_fail_count
                    raise AreSearch::Error, "失敗が多すぎます: max #{@max_fail_count}"
                end
            end

            # 送信待ちと保留中の1件分を合計したサイズを返す。
            def total_data_size
                @values_bytesize + @reserved_bytesize
            end

            # 送信待ちの件数を返す。
            def count
                @values_count
            end

            # 送信待ちをNDJSON文字列とskip対象IDで返し、返した送信待ちを初期化する。
            def take
                bulk_data = {
                    body: @values.join,
                    keys: @keys.dup,
                    skip_keys: @skip_keys.dup,
                    fail_key_and_errors: @fail_key_and_errors.dup,
                    check_point_key: @check_point_key,
                }

                @values = []
                @keys = []
                @skip_keys = []
                @fail_key_and_errors = []
                @values_bytesize = 0
                @values_count = 0

                if bulk_data[:keys].empty? && bulk_data[:skip_keys].empty? && bulk_data[:fail_key_and_errors].empty?
                    return nil
                else
                    bulk_data
                end
            end

            # 保留中の1件分を含む全データをNDJSON文字列で返し、全状態を初期化する。
            def take_all
                push_reserved
                take
            end

            private

            def push_reserved
                return if @reserved_key.nil?

                if @reserved_es_action == :skip
                    @skip_keys << @reserved_key
                elsif @reserved_es_action == :fail
                    @fail_key_and_errors << [@reserved_key, @reserved_index_data]
                else
                    @values << @reserved_es_action
                    @values << @reserved_index_data if @reserved_index_data.nil? == false
                    @keys << @reserved_key
                    @values_bytesize += @reserved_bytesize
                    @values_count += 1
                end

                @check_point_key = @reserved_key

                @reserved_key = nil
                @reserved_es_action = nil
                @reserved_index_data = nil
                @reserved_bytesize = 0
            end
        end

        class Logger

            CHECK_POINT_RESULT = "check_point"

            SUCCESS_RESULT   = "success"
            FAILURE_RESULT   = "fail"
            DATA_SKIP_RESULT = "data_skip"
            DATA_FAIL_RESULT = "data_fail"

            def initialize(check_point_file_path:, success_file_path:, failure_file_path:, data_skip_file_path:, data_fail_file_path:, log_file_path:)
                @check_point_file_path = check_point_file_path

                @success_file_path   = success_file_path
                @failure_file_path   = failure_file_path
                @data_skip_file_path = data_skip_file_path
                @data_fail_file_path = data_fail_file_path

                @log_file_path = log_file_path

                @fail_count = 0
            end

            def set_fail_count
                @fail_count = get_fail_key_uniq_size
            end

            # 結果ファイルの1項目として記録できないIDか確認する。
            def invalid_key?(key)
                not_nil_key = key.to_s

                not_nil_key.empty? || not_nil_key.match?(/\s/)
            end

            # 成功IDをチェックポイントファイルへ追記する。
            def write_check_point!(key)
                return if @check_point_file_path.nil?

                line = "[#{log_time}] #{key} #{CHECK_POINT_RESULT}\n"

                append_line!(@check_point_file_path, line)
            end

            # 成功IDを成功結果ファイルと全件ログへ追記する。
            def write_success_result!(key)
                line = "[#{log_time}] #{key} #{SUCCESS_RESULT}\n"

                append_line!(@success_file_path, line)
                append_line!(@log_file_path, line)
            end

            # skip IDをskip結果ファイルと全件ログへ追記する。
            def write_data_skip_result!(key)
                line = "[#{log_time}] #{key} #{DATA_SKIP_RESULT}\n"

                append_line!(@data_skip_file_path, line)
                append_line!(@log_file_path, line)
            end

            # 失敗IDを失敗結果ファイルへ、原因を含む結果を全件ログへ追記する。
            def write_failure_result!(key, error)
                fail_common(key, error, FAILURE_RESULT, @failure_file_path)
            end

            # skip IDをskip結果ファイルと全件ログへ追記する。
            def write_data_fail_result!(key, error)
                fail_common(key, error, DATA_FAIL_RESULT, @data_fail_file_path)
            end

            def fail_common(key, error, log_type, log_file)
                time = log_time
                failure_line = "[#{time}] #{key} #{log_type}\n"
                error_message = error.inspect

                if error.respond_to?(:message)
                    error_message = "#{error.class}: #{error.message}"
                end

                error_message = error_message.gsub(/[\r\n]+/, " ")
                log_line = "[#{time}] #{key} #{error_message} #{log_type}\n"

                append_line!(log_file, failure_line)
                append_line!(@log_file_path, log_line)

                @fail_count += 1
            end

            def fail_count
                @fail_count
            end

            # 成功結果ファイル、skip結果ファイル、失敗結果の最後のIDの組を返す
            def get_last_check_point_key
                read_last_result_key(@check_point_file_path, CHECK_POINT_RESULT)
            end

            # 全結果ファイルに記録済みの全IDを返す。
            def get_all_keys
                read_result_keys(@success_file_path,   SUCCESS_RESULT) +
                read_result_keys(@failure_file_path,   FAILURE_RESULT) +
                read_result_keys(@data_skip_file_path, DATA_SKIP_RESULT) +
                read_result_keys(@data_fail_file_path, DATA_FAIL_RESULT)
            end

            # 失敗扱いの結果ファイルに記録済みの全IDを返す。
            def get_fail_keys
                read_result_keys(@failure_file_path,   FAILURE_RESULT) +
                read_result_keys(@data_fail_file_path, DATA_FAIL_RESULT)
            end

            def get_fail_key_uniq_size
                get_fail_keys.uniq.size
            end

            # 成功扱いの結果ファイルに記録済みの全IDを返す。
            def get_not_fail_keys
                read_result_keys(@success_file_path,   SUCCESS_RESULT) +
                read_result_keys(@data_skip_file_path, DATA_SKIP_RESULT)
            end

            # 指定ファイルの全IDを返す。
            def read_result_keys(file_path, expected_result)
                return [] unless File.exist?(file_path)

                keys = []

                File.foreach(file_path) do |line|
                    content_line = line.chomp
                    next if content_line.empty?

                    key = line_to_key(content_line, expected_result)

                    if key.nil?
                        raise AreSearch::Error, "ファイルに不正な行があります: #{file_path}, line #{content_line}"
                    end

                    keys << key
                end

                keys
            end

            # recoverで使用した結果ファイルを同じ退避ディレクトリへ移動する。
            def rename_all(additional_files)
                file_paths = [
                    @success_file_path,
                    @failure_file_path,
                    @data_skip_file_path,
                    @data_fail_file_path,
                ] + additional_files

                suffix = Time.current.strftime("%Y_%m_%d_%H_%M_%S_%6N")
                archive_dir = File.join(File.dirname(@log_file_path), "recover_#{suffix}")
                Dir.mkdir(archive_dir)

                renamed_files = []

                begin
                    file_paths.each do |file_path|
                        next unless File.exist?(file_path)

                        renamed_file_path = File.join(archive_dir, File.basename(file_path))
                        File.rename(file_path, renamed_file_path)
                        renamed_files << [file_path, renamed_file_path]
                    end
                rescue StandardError
                    renamed_files.reverse_each do |file_path, renamed_file_path|
                        File.rename(renamed_file_path, file_path)
                    end

                    Dir.rmdir(archive_dir)
                    raise
                end

                nil
            end

            private

            def log_time
                Time.current.iso8601(6)
            end

            # 完成した1行を指定ファイルへ追記する。
            def append_line!(file_path, line)
                File.open(file_path, File::WRONLY | File::APPEND | File::CREAT) do |file|
                    file.write(line)
                    file.flush
                    file.fsync
                end
            end

            # 最後の内容行が期待する結果形式ならIDを返す。
            def read_last_result_key(file_path, expected_result)
                last_line = read_last_content_line(file_path)
                return nil if last_line.nil?

                key = line_to_key(last_line, expected_result)

                if key.nil?
                    raise AreSearch::Error, "ファイルに不正な行があります: #{file_path}, line #{last_line}"
                end

                key
            end

            # 行が期待する結果形式ならIDを返す。
            def line_to_key(line, expected_result)
                pattern = /\A\[[^\]\r\n]+\] (\S+) #{Regexp.escape(expected_result)}\z/
                matched = line.match(pattern)

                if matched.nil?
                    nil
                else
                    matched[1]
                end
            end

            # 末尾の空行を飛ばし、最後の内容行だけを返す。
            def read_last_content_line(file_path)
                return nil unless File.exist?(file_path)

                File.open(file_path, "rb") do |file|
                    end_position = seek_back(file, file.size - 1, check_chars: ["\r", "\n"], include: true)
                    return nil if end_position < 0

                    start_position = seek_back(file, end_position, check_chars: ["\n"], include: false)

                    file.seek(start_position + 1)
                    line = file.read(end_position - start_position).force_encoding(Encoding::UTF_8)

                    unless line.valid_encoding?
                        raise AreSearch::Error, "ファイルに不正な文字があります: #{file_path}"
                    end

                    line
                end
            end

            # check_charsに含まれるかがincludeと一致する間だけ後方へ進み、外れた位置を返す。
            def seek_back(file, position, check_chars:, include:)
                while position >= 0
                    file.seek(position)
                    break if check_chars.include?(file.read(1)) != include

                    position -= 1
                end

                position
            end
        end
    end
end
