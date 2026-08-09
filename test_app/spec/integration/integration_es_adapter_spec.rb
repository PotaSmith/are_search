# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch EsAdapter integration", type: :model do
    self.use_transactional_tests = false

    around do |example|
        delete_test_indices
        example.run
    ensure
        delete_test_indices
    end

    # EsAdapter単体確認用のalias名を返す。
    def test_index_alias_name
        "#{AreSearch.index_prefix}__es_adapter_integration__default"
    end

    # EsAdapter単体確認用の物理index名を返す。
    def test_physical_index_name(sequence)
        "#{test_index_alias_name}__2026_08_08_20_30_00_#{format('%06d', sequence)}"
    end

    # long型1項目だけを持つ物理indexを作成する。
    def create_test_physical_index(physical_index_name)
        AreSearch::EsAdapter.indices_create(
            physical_index_name: physical_index_name,
            body: {
                mappings: {
                    properties: {
                        value: { type: "long" },
                    },
                },
            },
        )
    end

    # 指定物理indexへテスト用aliasを接続する。
    def add_test_alias(physical_index_name)
        AreSearch.client.indices.update_aliases(
            body: {
                actions: [
                    {
                        add: {
                            index: physical_index_name,
                            alias: test_index_alias_name,
                        },
                    },
                ],
            },
        )
    end

    # integration specが作成したElasticsearch indexを削除する。
    def delete_test_indices
        response = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: test_index_alias_name,
        )

        response.keys.each do |physical_index_name|
            AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )
        end

        return if AreSearch::EsAdapter.index_alias_exists?(
            index_alias_name: test_index_alias_name,
        )

        alias_named_response = AreSearch::EsAdapter.alias_named_physical_index(
            index_alias_name: test_index_alias_name,
        )
        return unless alias_named_response.keys.include?(test_index_alias_name)

        AreSearch.client.indices.delete(index: test_index_alias_name)
    end

    it "indices_createの実応答で物理indexが作成される" do
        physical_index_name = test_physical_index_name(1)

        response = create_test_physical_index(physical_index_name)

        expect(response["acknowledged"]).to eq(true)
        expect(response["index"]).to eq(physical_index_name)
        expect(
            AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: test_index_alias_name,
            ).keys,
        ).to include(physical_index_name)
    end

    it "index search deleteの実応答をAreSearchの契約へ変換する" do
        physical_index_name = test_physical_index_name(1)
        create_test_physical_index(physical_index_name)
        add_test_alias(physical_index_name)

        index_response = AreSearch::EsAdapter.index(
            index_alias_name: test_index_alias_name,
            es_key:           "1",
            body:             { value: 123 },
        )

        expect(["created", "updated"]).to include(index_response["result"])
        expect(index_response["_id"]).to eq("1")

        AreSearch.client.indices.refresh(index: test_index_alias_name)

        search_response = AreSearch::EsAdapter.no_validation_search(
            index: test_index_alias_name,
            body: {
                query: {
                    term: {
                        value: 123,
                    },
                },
            },
        )

        expect(search_response.dig("hits", "total", "value")).to eq(1)
        expect(search_response.dig("hits", "hits", 0, "_id")).to eq("1")

        expect(
            AreSearch::EsAdapter.delete(
                index_alias_name: test_index_alias_name,
                es_key:           "1",
            ),
        ).to eq(AreSearch::EsAdapter.success)

        expect(
            AreSearch::EsAdapter.delete(
                index_alias_name: test_index_alias_name,
                es_key:           "1",
            ),
        ).to eq(AreSearch::EsAdapter.not_found)
    end

    it "bulkの一部失敗をitems内のerrorとして返す" do
        physical_index_name = test_physical_index_name(1)
        create_test_physical_index(physical_index_name)
        add_test_alias(physical_index_name)

        response = AreSearch::EsAdapter.no_validation_bulk(
            body: [
                { index: { _index: test_index_alias_name, _id: "1" } },
                { value: 1 },
                { index: { _index: test_index_alias_name, _id: "2" } },
                { value: 10 ** 30 },
            ],
        )

        expect(response["errors"]).to eq(true)
        expect(response["items"].length).to eq(2)
        expect(response.dig("items", 0, "index", "_id")).to eq("1")
        expect(response.dig("items", 0, "index", "error")).to eq(nil)
        expect(response.dig("items", 1, "index", "_id")).to eq("2")
        expect(response.dig("items", 1, "index", "error")).not_to eq(nil)
    end

    it "alias取得と物理index列挙を実Elasticsearchの応答で判定する" do
        first_physical_index_name = test_physical_index_name(1)
        second_physical_index_name = test_physical_index_name(2)

        create_test_physical_index(first_physical_index_name)
        create_test_physical_index(second_physical_index_name)
        add_test_alias(first_physical_index_name)

        expect(
            AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: test_index_alias_name,
            ),
        ).to eq(true)

        alias_response = AreSearch::EsAdapter.indices_get_alias(
            index_alias_name: test_index_alias_name,
        )
        expect(alias_response.keys).to eq([first_physical_index_name])

        physical_response = AreSearch::EsAdapter.physical_indices_for_alias(
            index_alias_name: test_index_alias_name,
        )
        expect(physical_response.keys.sort).to eq(
            [first_physical_index_name, second_physical_index_name].sort,
        )

        prefix_response = AreSearch::EsAdapter.indices_for_prefix(
            index_prefix: AreSearch.index_prefix,
        )
        expect(prefix_response.keys).to include(
            first_physical_index_name,
            second_physical_index_name,
        )

        missing_alias_name = "#{AreSearch.index_prefix}__es_adapter_missing__default"
        expect(
            AreSearch::EsAdapter.indices_get_alias(
                index_alias_name: missing_alias_name,
            ),
        ).to eq({})
    end

    it "update_aliasの実応答をsuccessとして判定して接続先を切り替える" do
        old_physical_index_name = test_physical_index_name(1)
        new_physical_index_name = test_physical_index_name(2)

        create_test_physical_index(old_physical_index_name)
        create_test_physical_index(new_physical_index_name)
        add_test_alias(old_physical_index_name)

        result = AreSearch::EsAdapter.update_alias(
            old_physical_index_names: [old_physical_index_name],
            new_physical_index_name:  new_physical_index_name,
        )

        expect(result).to eq(AreSearch::EsAdapter.success)
        expect(
            AreSearch::EsAdapter.indices_get_alias(
                index_alias_name: test_index_alias_name,
            ).keys,
        ).to eq([new_physical_index_name])
    end

    it "alias名と同名の物理indexを取得して削除できる" do
        AreSearch.client.indices.create(index: test_index_alias_name)

        response = AreSearch::EsAdapter.alias_named_physical_index(
            index_alias_name: test_index_alias_name,
        )

        expect(response.keys).to eq([test_index_alias_name])
        expect(
            AreSearch::EsAdapter.alias_named_physical_index_exists?(
                index_alias_name: test_index_alias_name,
            ),
        ).to eq(true)

        expect(
            AreSearch::EsAdapter.delete_alias_named_physical_index(
                index_alias_name: test_index_alias_name,
            ),
        ).to eq(AreSearch::EsAdapter.success)

        expect(
            AreSearch::EsAdapter.delete_alias_named_physical_index(
                index_alias_name: test_index_alias_name,
            ),
        ).to eq(AreSearch::EsAdapter.not_found)
    end

    it "通常aliasからalias名と同名の物理indexを取得しない" do
        physical_index_name = test_physical_index_name(1)
        create_test_physical_index(physical_index_name)
        add_test_alias(physical_index_name)

        response = AreSearch::EsAdapter.alias_named_physical_index(
            index_alias_name: test_index_alias_name,
        )

        expect(response).to eq({})
        expect(
            AreSearch::EsAdapter.alias_named_physical_index_exists?(
                index_alias_name: test_index_alias_name,
            ),
        ).to eq(false)
    end
end
