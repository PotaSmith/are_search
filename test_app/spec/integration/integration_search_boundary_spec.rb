# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch search boundary integration", type: :model do
    self.use_transactional_tests = false

    around do |example|
        original_after_commit_mode = AreSearch.after_commit_mode
        original_index_operation_enabled = AreSearch.index_operation_enabled

        AreSearch.after_commit_mode = :direct
        AreSearch.index_operation_enabled = true

        clear_records
        rebuild_index
        example.run
    ensure
        clear_records

        AreSearch.after_commit_mode = original_after_commit_mode
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    # DocumentSecondの標準IndexTargetを返す。
    def index_target
        DocumentSecond.are_search_index_target(:default)
    end

    # DocumentSecondのindexを現在定義から作り直す。
    def rebuild_index
        result = index_target.are_search_reindex(
            stage_position: :first,
        )

        expect(result[:result]).to eq(:success)
    end

    # integration specが作成したDB状態を削除する。
    def clear_records
        DocumentSecond.delete_all
        AreSearch::SyncRequest.delete_all
        AreSearch::IndexMarker.delete_all
    end

    # DocumentSecondのindexをrefreshする。
    def refresh_index
        AreSearch.client.indices.refresh(
            index: index_target.are_search_index_alias_name,
        )
    end

    it "runtime_mappingsを実Elasticsearchで評価してresponse.fieldsへ返す" do
        document = DocumentSecond.create!(
            title:   "runtimeboundarytoken",
            body:    "runtime mapping integration",
            status:  "published",
            user_id: 1201,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "runtimeboundarytoken",
                    fields:       [:title],
                },
            ],
            runtime_mappings: {
                runtime_user_double: {
                    type: "long",
                    script: {
                        source: "emit(doc['user_id'].value * 2)",
                    },
                },
            },
            enable_runtime_mappings: true,
            response: {
                fields: ["runtime_user_double"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:fields][:runtime_user_double]).to eq([2402])
    end

    it "response.sourceに指定しても_sourceへ保存していないフィールドは返らない" do
        document = DocumentSecond.create!(
            title:   "missingresponseboundarytoken",
            body:    "not stored in source",
            status:  "published",
            user_id: 1203,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "missingresponseboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                source: ["body"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source]).not_to have_key(:body)
    end

    it "response.fieldsに指定しても_sourceへ保存していない通常フィールドは返らない" do
        document = DocumentSecond.create!(
            title:   "missingfieldsboundarytoken",
            body:    "not stored in source for fields",
            status:  "published",
            user_id: 1204,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "missingfieldsboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                fields: ["body"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:fields]).not_to have_key(:body)
    end

    it "response.stored_fieldsで_sourceへ保存していないstore済みフィールドを返す" do
        document = DocumentSecond.create!(
            title:   "storedfieldsboundarytoken",
            body:    "stored fields response body",
            status:  "published",
            user_id: 1205,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "storedfieldsboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                stored_fields: ["body"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source]).not_to have_key(:body)
        expect(hit[:fields][:body]).to eq([
            "stored fields response body",
        ])
    end

    it "response.docvalue_fieldsで_sourceへ保存していないdoc_valuesを返す" do
        document = DocumentSecond.create!(
            title:   "docvaluefieldsboundarytoken",
            body:    "docvalue fields response body",
            status:  "published",
            user_id: 1206,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "docvaluefieldsboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                docvalue_fields: ["user_id"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source]).not_to have_key(:user_id)
        expect(hit[:fields][:user_id]).to eq([1206])
    end

    it "response.sourceとresponse.fieldsを実Elasticsearchのhitから復元する" do
        document = DocumentSecond.create!(
            title:   "responseboundarytoken",
            body:    "stored response body",
            status:  "published",
            user_id: 1202,
        )

        refresh_index

        result = AreSearch::Searcher.search(
            [index_target],
            queries: [
                {
                    query_string: "responseboundarytoken",
                    fields:       [:title],
                },
            ],
            response: {
                source: ["title"],
                fields: ["status"],
            },
        )

        expect(result.status).to eq(AreSearch::SearchResult::STATUS_OK)
        expect(result.records.map(&:id)).to eq([document.id])

        record, hit = result.records_with_hit.first
        expect(record.id).to eq(document.id)
        expect(hit[:source][:title]).to eq("responseboundarytoken")
        expect(hit[:fields][:status]).to eq(["published"])
    end
end
