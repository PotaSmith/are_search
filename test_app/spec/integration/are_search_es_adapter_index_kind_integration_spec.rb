# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AreSearch EsAdapter index kind integration", type: :model do
    self.use_transactional_tests = false

    around do |example|
        delete_test_patterns
        create_test_patterns

        example.run
    ensure
        delete_test_patterns
    end

    # 実Elasticsearch上の状態をEsAdapter自身に依存せず作るための共通mapping。
    def test_index_body
        {
            mappings: {
                properties: {
                    value: { type: "long" },
                },
            },
        }
    end

    # 1. 通常のtimestamp付き物理index名。
    def physical_index_name
        "#{AreSearch.index_prefix}__es_adapter_pattern_physical__default" \
            "__2026_08_08_21_50_00_000001"
    end

    # 2. 通常alias名。
    def index_alias_name
        "#{AreSearch.index_prefix}__es_adapter_pattern_alias__default"
    end

    # 2. 通常aliasが指すtimestamp付き物理index名。
    def index_alias_backing_physical_name
        "#{index_alias_name}__2026_08_08_21_50_00_000002"
    end

    # 3. alias形式の名前を持つ物理index名。
    def alias_named_physical_index_name
        "#{AreSearch.index_prefix}__es_adapter_pattern_alias_named__default"
    end

    # 4. timestamp付き物理index形式の名前を持つalias名。
    def physical_index_named_alias_name
        "#{AreSearch.index_prefix}__es_adapter_pattern_physical_alias__default" \
            "__2026_08_08_21_50_00_000003"
    end

    # 4. 物理index形式名のaliasが指すtimestamp付き物理index名。
    def physical_index_named_alias_backing_name
        "#{AreSearch.index_prefix}__es_adapter_pattern_physical_alias_backing__default" \
            "__2026_08_08_21_50_00_000004"
    end

    # indices_createの実呼び出しに使用するbodyを返す。
    def indices_create_body
        test_index_body
    end

    # 4パターンを毎example同じ状態で実Elasticsearchへ作成する。
    # fixture作成ではEsAdapterを使用しない。
    def create_test_patterns
        client = AreSearch.client

        client.indices.create(
            index: physical_index_name,
            body:  test_index_body,
        )
        client.indices.create(
            index: index_alias_backing_physical_name,
            body:  test_index_body,
        )
        client.indices.create(
            index: alias_named_physical_index_name,
            body:  test_index_body,
        )
        client.indices.create(
            index: physical_index_named_alias_backing_name,
            body:  test_index_body,
        )

        client.indices.update_aliases(
            body: {
                actions: [
                    {
                        add: {
                            index: index_alias_backing_physical_name,
                            alias: index_alias_name,
                        },
                    },
                    {
                        add: {
                            index: physical_index_named_alias_backing_name,
                            alias: physical_index_named_alias_name,
                        },
                    },
                ],
            },
        )
    end

    # このspecが作成した全物理indexを直接削除する。
    # 物理indexを削除すれば、それを指すaliasも同時に消える。
    def delete_test_patterns
        pattern = "#{AreSearch.index_prefix}__es_adapter_pattern*"

        response = AreSearch.client.indices.get(index: pattern)

        response.keys.each do |index_name|
            AreSearch.client.indices.delete(index: index_name)
        rescue Elastic::Transport::Transport::Errors::NotFound
            nil
        end
    rescue Elastic::Transport::Transport::Errors::NotFound
        nil
    end

    describe ".indices_get_alias" do
        it "物理indexを指定した場合はalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.indices_get_alias(
                    index_alias_name: physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end

        it "aliasを指定した場合は接続先の物理indexを返す" do
            result = AreSearch::EsAdapter.indices_get_alias(
                index_alias_name: index_alias_name,
            )

            expect(result.keys).to eq([
                index_alias_backing_physical_name,
            ])
        end

        it "alias名の物理indexを指定した場合はaliasではないため空Hashを返す" do
            result = AreSearch::EsAdapter.indices_get_alias(
                index_alias_name: alias_named_physical_index_name,
            )

            expect(result).to eq({})
        end

        it "物理index名のaliasを指定した場合はAreSearchのalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.indices_get_alias(
                    index_alias_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end
    end

    describe ".physical_indices_for_alias" do
        it "物理indexを指定した場合はalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.physical_indices_for_alias(
                    index_alias_name: physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end

        it "aliasを指定した場合はそのaliasから生成された物理indexを返す" do
            result = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: index_alias_name,
            )

            expect(result.keys).to eq([
                index_alias_backing_physical_name,
            ])
        end

        it "alias名の物理indexを指定した場合はtimestamp付き物理indexが無いため空結果を返す" do
            result = AreSearch::EsAdapter.physical_indices_for_alias(
                index_alias_name: alias_named_physical_index_name,
            )

            expect(result.keys).to eq([])
        end

        it "物理index名のaliasを指定した場合はAreSearchのalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.physical_indices_for_alias(
                    index_alias_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end
    end

    describe ".alias_named_physical_index" do
        it "物理indexを指定した場合はalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.alias_named_physical_index(
                    index_alias_name: physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end

        it "aliasを指定した場合はalias名と同名の物理indexを返さない" do
            result = AreSearch::EsAdapter.alias_named_physical_index(
                index_alias_name: index_alias_name,
            )

            expect(result).to eq({})
        end

        it "alias名の物理indexを指定した場合はその物理indexを返す" do
            result = AreSearch::EsAdapter.alias_named_physical_index(
                index_alias_name: alias_named_physical_index_name,
            )

            expect(result.keys).to eq([
                alias_named_physical_index_name,
            ])
        end

        it "物理index名のaliasを指定した場合はAreSearchのalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.alias_named_physical_index(
                    index_alias_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end
    end

    describe ".index_alias_exists?" do
        it "物理indexを指定した場合はalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.index_alias_exists?(
                    index_alias_name: physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end

        it "aliasを指定した場合はtrueを返す" do
            result = AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: index_alias_name,
            )

            expect(result).to eq(true)
        end

        it "alias名の物理indexを指定した場合はfalseを返す" do
            result = AreSearch::EsAdapter.index_alias_exists?(
                index_alias_name: alias_named_physical_index_name,
            )

            expect(result).to eq(false)
        end

        it "物理index名のaliasを指定した場合はAreSearchのalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.index_alias_exists?(
                    index_alias_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end
    end

    describe ".alias_named_physical_index_exists?" do
        it "物理indexを指定した場合はalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.alias_named_physical_index_exists?(
                    index_alias_name: physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end

        it "aliasを指定した場合はfalseを返す" do
            result = AreSearch::EsAdapter.alias_named_physical_index_exists?(
                index_alias_name: index_alias_name,
            )

            expect(result).to eq(false)
        end

        it "alias名の物理indexを指定した場合はtrueを返す" do
            result = AreSearch::EsAdapter.alias_named_physical_index_exists?(
                index_alias_name: alias_named_physical_index_name,
            )

            expect(result).to eq(true)
        end

        it "物理index名のaliasを指定した場合はAreSearchのalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.alias_named_physical_index_exists?(
                    index_alias_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )
        end
    end

    describe ".delete_physical_index" do
        it "物理indexを指定した場合は削除する" do
            result = AreSearch::EsAdapter.delete_physical_index(
                physical_index_name: physical_index_name,
            )

            expect(result).to eq(AreSearch::EsAdapter.success)
            expect(
                AreSearch.client.indices.exists(
                    index: physical_index_name,
                ),
            ).to eq(false)
        end

        it "aliasを指定した場合は物理index名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.delete_physical_index(
                    physical_index_name: index_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な物理 index 名です",
            )

            expect(
                AreSearch.client.indices.exists_alias(
                    name: index_alias_name,
                ),
            ).to eq(true)
        end

        it "alias名の物理indexを指定した場合は物理index名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.delete_physical_index(
                    physical_index_name: alias_named_physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な物理 index 名です",
            )

            expect(
                AreSearch.client.indices.exists(
                    index: alias_named_physical_index_name,
                ),
            ).to eq(true)
        end

        it "物理index名のaliasを指定した場合はElasticsearchのBadRequestを送出して削除しない" do
            expect do
                AreSearch::EsAdapter.delete_physical_index(
                    physical_index_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                Elastic::Transport::Transport::Errors::BadRequest,
            )

            expect(
                AreSearch.client.indices.exists_alias(
                    name: physical_index_named_alias_name,
                ),
            ).to eq(true)
            expect(
                AreSearch.client.indices.exists(
                    index: physical_index_named_alias_backing_name,
                ),
            ).to eq(true)
        end
    end

    describe ".delete_alias_named_physical_index" do
        it "物理indexを指定した場合はalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.delete_alias_named_physical_index(
                    index_alias_name: physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )

            expect(
                AreSearch.client.indices.exists(
                    index: physical_index_name,
                ),
            ).to eq(true)
        end

        it "aliasを指定した場合はElasticsearchのBadRequestを送出して削除しない" do
            expect do
                AreSearch::EsAdapter.delete_alias_named_physical_index(
                    index_alias_name: index_alias_name,
                )
            end.to raise_error(
                Elastic::Transport::Transport::Errors::BadRequest,
            )

            expect(
                AreSearch.client.indices.exists_alias(
                    name: index_alias_name,
                ),
            ).to eq(true)
            expect(
                AreSearch.client.indices.exists(
                    index: index_alias_backing_physical_name,
                ),
            ).to eq(true)
        end

        it "alias名の物理indexを指定した場合はその物理indexを削除する" do
            result = AreSearch::EsAdapter.delete_alias_named_physical_index(
                index_alias_name: alias_named_physical_index_name,
            )

            expect(result).to eq(AreSearch::EsAdapter.success)
            expect(
                AreSearch.client.indices.exists(
                    index: alias_named_physical_index_name,
                ),
            ).to eq(false)
        end

        it "物理index名のaliasを指定した場合はAreSearchのalias名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.delete_alias_named_physical_index(
                    index_alias_name: physical_index_named_alias_name,
                )
            end.to raise_error(
                ArgumentError,
                "不正な Elasticsearch alias 名です",
            )

            expect(
                AreSearch.client.indices.exists_alias(
                    name: physical_index_named_alias_name,
                ),
            ).to eq(true)
        end
    end

    describe ".indices_create" do
        it "物理indexを指定した場合は既に存在するためElasticsearchのエラーをそのまま送出する" do
            expect do
                AreSearch::EsAdapter.indices_create(
                    physical_index_name: physical_index_name,
                    body:                indices_create_body,
                )
            end.to raise_error(
                Elastic::Transport::Transport::Errors::BadRequest,
            )

            expect(
                AreSearch.client.indices.exists(
                    index: physical_index_name,
                ),
            ).to eq(true)
        end

        it "aliasを指定した場合は物理index名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.indices_create(
                    physical_index_name: index_alias_name,
                    body:                indices_create_body,
                )
            end.to raise_error(
                ArgumentError,
                "不正な物理 index 名です",
            )

            expect(
                AreSearch.client.indices.exists_alias(
                    name: index_alias_name,
                ),
            ).to eq(true)
        end

        it "alias名の物理indexを指定した場合は物理index名ではないため拒否する" do
            expect do
                AreSearch::EsAdapter.indices_create(
                    physical_index_name: alias_named_physical_index_name,
                    body:                indices_create_body,
                )
            end.to raise_error(
                ArgumentError,
                "不正な物理 index 名です",
            )

            expect(
                AreSearch.client.indices.exists(
                    index: alias_named_physical_index_name,
                ),
            ).to eq(true)
        end

        it "物理index名のaliasを指定した場合は同名aliasが存在するためElasticsearchのエラーをそのまま送出する" do
            expect do
                AreSearch::EsAdapter.indices_create(
                    physical_index_name: physical_index_named_alias_name,
                    body:                indices_create_body,
                )
            end.to raise_error(
                Elastic::Transport::Transport::Errors::BadRequest,
            )

            expect(
                AreSearch.client.indices.exists_alias(
                    name: physical_index_named_alias_name,
                ),
            ).to eq(true)
        end
    end
end
