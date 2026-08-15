# frozen_string_literal: true

module AreSearchIntegrationSupport

    # integration spec で使用するモデルの IndexTarget を返す。
    def integration_index_target(model_class, index_target_name = :default)
        model_class.are_search_index_target(index_target_name)
    end

    # 指定した IndexTarget を現在のモデル定義から reindex する。
    def reindex_integration_indexes(index_targets)
        results = []

        index_targets.each do |index_target|
            results << index_target.are_search_reindex(
                stage_position: :first,
            )
        end

        results
    end

    # 指定した IndexTarget を refresh して直後の検索から参照できるようにする。
    def refresh_integration_indexes(index_targets)
        responses = []

        index_targets.each do |index_target|
            responses << AreSearch.client.indices.refresh(
                index: index_target.are_search_index_alias_name,
            )
        end

        responses
    end

    # 単一 IndexTarget の標準検索入口を使って検索する。
    def search_integration_index(
        index_target,
        query,
        fields: [:title, :body],
        **options
    )
        index_target.are_search_search(
            query,
            fields: fields,
            **options,
        )
    end

    # 複数 IndexTarget の標準検索入口を使って検索する。
    def search_integration_indexes(
        index_targets,
        query,
        fields: [:title, :body],
        **options
    )
        AreSearch::Searcher.search(
            index_targets,
            queries: [
                {
                    query_string: query,
                    fields:       fields,
                },
            ],
            **options,
        )
    end

    # integration spec 中だけ AreSearch の実行設定を変更し、終了時に元へ戻す。
    def with_are_search_integration_settings(
        after_commit_mode:,
        index_operation_enabled:
    )
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = after_commit_mode
        AreSearch.index_operation_enabled = index_operation_enabled

        yield
    ensure
        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # 指定モデルと AreSearch の integration spec 用DB状態を削除する。
    def clear_are_search_integration_records(model_classes = [DocumentFirst])
        model_classes.each do |model_class|
            model_class.delete_all
        end

        AreSearch::SyncRequest.delete_all
        AreSearch::SyncLock.delete_all
    end

    # DocumentFirst の標準 IndexTarget を返す。
    def document_first_index_target
        integration_index_target(DocumentFirst)
    end

    # DocumentFirst の現在定義から空の index を作り直す。
    def rebuild_empty_document_first_index
        clear_are_search_integration_records

        reindex_integration_indexes(
            [document_first_index_target],
        ).first
    end

    # DocumentFirst の index を refresh して直後の検索から参照できるようにする。
    def refresh_document_first_index
        refresh_integration_indexes(
            [document_first_index_target],
        ).first
    end

    # DocumentFirst の title / body を対象に検索する。
    def search_document_first(query, index_target: document_first_index_target)
        search_integration_index(
            index_target,
            query,
        )
    end

    # test_app と同じ AreSearch gem に含まれる generator template のパスを返す。
    def are_search_template_path(file_name)
        gem_root = Gem.loaded_specs.fetch("are_search").full_gem_path

        File.join(
            gem_root,
            "lib",
            "generators",
            "are_search",
            "templates",
            file_name,
        )
    end
end
