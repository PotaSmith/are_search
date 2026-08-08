# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::EsAdapter do
    let(:indices) { double("indices") }
    let(:client) { double("client", indices: indices) }

    before do
        allow(AreSearch)
            .to receive(:client)
            .and_return(client)
    end

    describe ".update_alias" do
        let(:new_physical_index_name) do
            "test__articles__default__2026_08_04_12_00_00_000000"
        end

        it "旧物理index名はArrayで指定する" do
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.update_alias(
                    old_physical_index_names: "test__articles__default__2026_08_03_12_00_00_000000",
                    new_physical_index_name:  new_physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "old_physical_index_names は Array で指定してください",
            )
        end

        it "新旧物理indexのalias名が一致しなければ拒否する" do
            expect(indices).not_to receive(:update_aliases)

            expect do
                described_class.update_alias(
                    old_physical_index_names: [
                        "test__articles__archive__2026_08_03_12_00_00_000000",
                    ],
                    new_physical_index_name: new_physical_index_name,
                )
            end.to raise_error(
                ArgumentError,
                "old_physical_index_names と new_physical_index_name の alias 名が一致しません",
            )
        end

        it "旧物理indexのremoveと新物理indexのaddを送信して成功を返す" do
            old_physical_index_names = [
                "test__articles__default__2026_08_02_12_00_00_000000",
                "test__articles__default__2026_08_03_12_00_00_000000",
            ]

            expect(indices)
                .to receive(:update_aliases)
                .with(
                    body: {
                        actions: [
                            {
                                remove: {
                                    index: old_physical_index_names[0],
                                    alias: "test__articles__default",
                                },
                            },
                            {
                                remove: {
                                    index: old_physical_index_names[1],
                                    alias: "test__articles__default",
                                },
                            },
                            {
                                add: {
                                    index: new_physical_index_name,
                                    alias: "test__articles__default",
                                },
                            },
                        ],
                    },
                )
                .and_return(
                    "acknowledged" => true,
                    "errors"       => false,
                )

            expect(indices).not_to receive(:get_alias)

            result = described_class.update_alias(
                old_physical_index_names: old_physical_index_names,
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.success)
        end

        it "alias更新APIがaction失敗を返した場合は失敗を返す" do
            allow(indices)
                .to receive(:update_aliases)
                .and_return(
                    "acknowledged"   => true,
                    "errors"         => true,
                    "action_results" => [],
                )

            expect(indices).not_to receive(:get_alias)

            result = described_class.update_alias(
                old_physical_index_names: [],
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.not_success)
        end

        it "alias更新APIの応答で成否不明でも新物理indexだけを指していれば成功を返す" do
            allow(indices)
                .to receive(:update_aliases)
                .and_return("acknowledged" => false)

            expect(indices)
                .to receive(:get_alias)
                .with(name: "test__articles__default")
                .and_return(new_physical_index_name => {})

            result = described_class.update_alias(
                old_physical_index_names: [],
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.success)
        end

        it "alias更新APIの応答で成否不明かつ接続先が一致しなければ失敗を返す" do
            allow(indices)
                .to receive(:update_aliases)
                .and_return("acknowledged" => false)

            expect(indices)
                .to receive(:get_alias)
                .with(name: "test__articles__default")
                .and_return(
                    "test__articles__default__2026_08_03_12_00_00_000000" => {},
                )

            result = described_class.update_alias(
                old_physical_index_names: [],
                new_physical_index_name:  new_physical_index_name,
            )

            expect(result).to eq(described_class.not_success)
        end
    end
end
