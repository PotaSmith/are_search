# frozen_string_literal: true

module AreSearch
    module SyncRequestRunner
        extend self

        # 渡された同期要求scopeを、指定されたモデルとprocessing tokenに限定して処理する。
        # lockを取得できなかった場合はnil、実行した場合は処理件数をHashで返す。
        def run( models:, normal_scope:, force_scope:, processing_token:, lock_file_path:)
            if processing_token.blank?
                raise ArgumentError, "processing_token を指定してください"
            end

            lock_path = lock_file_path.to_s

            if lock_path.empty?
                raise ArgumentError, "lock_file_path を指定してください"
            end

            # 多重起動を防ぐためロックファイルを flock で排他ロックする。
            # ロックはファイルディスクリプタに紐づき、プロセス終了時にOSが自動解放する。
            # File.open のブロック形にすることで、ブロック離脱時の close で解放が保証され、
            # かつブロック内にいる間ファイルオブジェクトの参照が生きるためGCによる早期解放も防げる。

            # locks/sync_runner/ が存在しない場合に備えてディレクトリを作成する。
            # これがないと下の File.open が Errno::ENOENT で失敗する。
            FileUtils.mkdir_p(File.dirname(lock_path))

            # 無ければ作る・あれば中身は触らない（RDWR | CREAT、切り詰めなし）
            File.open(lock_path, File::RDWR | File::CREAT) do |lock_file|
                # LOCK_NB（ノンブロッキング）で即座に取得可否を返す。
                # 取得できなければ別の処理が実行中なので、待たずに終了する。
                locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB)
                return nil unless locked

                return run_with_lock(models, normal_scope, force_scope, processing_token)
            end
        end

        private

        # lock取得中に通常同期とforce同期を順番に実行し、それぞれの対象件数を返す。
        def run_with_lock(models, normal_scope, force_scope, processing_token)
            model_class_names = models.map(&:name)

            normal_count = run_normal_sync_requests(
                normal_scope,
                model_class_names,
                processing_token,
            )

            force_count = run_force_sync_requests(
                force_scope,
                model_class_names,
                processing_token,
            )

            {
                normal_count: normal_count,
                force_count:  force_count,
            }
        end

        # 通常同期。
        # 未処理または同じprocessing tokenで中断した通常同期要求を処理する。
        def run_normal_sync_requests(normal_scope, model_class_names, processing_token)
            requests = normal_scope
                .where(ar_model_class_name: model_class_names)
                .where(processing_token: [nil, processing_token])

            processed_count = 0

            requests.find_each do |sync_request|
                # 対象モデルが reindex 中の場合は sync_request 側でスキップされる。
                # last_error に "sync locked" が記録され、*_try_count は増えない。
                sync_request.are_search_try_sync(processing_token, on_rake: true)

                processed_count += 1
            end

            processed_count
        end

        # 強制同期。
        # 別のprocessing tokenを保持したまま残っているforce同期要求を処理する。
        def run_force_sync_requests(force_scope, model_class_names, processing_token)
            requests = force_scope
                .where(ar_model_class_name: model_class_names)
                .where.not(processing_token: nil)
                .where.not(processing_token: processing_token)

            processed_count = 0

            requests.find_each do |sync_request|
                # processing のまま返ってこない同期を force で強制同期する。ただし、復旧はしない。
                # request_sequence は条件に入れない。
                # 詰まり中に同じ行が upsert されると request_sequence は更新されるが、
                # force の対象は「現在この sync request 行が詰まっていること」だから。
                sync_request.are_search_try_force_sync

                processed_count += 1
            end

            processed_count
        end
    end
end
