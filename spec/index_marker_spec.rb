# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::IndexMarker do
    let(:es_index_name) { "test_articles" }

    around do |example|
        original_index_operation_enabled = AreSearch.index_operation_enabled
        AreSearch.index_operation_enabled = true

        example.run
    ensure
        AreSearch.index_operation_enabled = original_index_operation_enabled
    end

    def create_index_marker(attrs = {})
        defaults = {
            es_index_name: es_index_name,
            operation:     "reindex",
            owner_token:   SecureRandom.uuid,
            owner_host:    "test-host",
            owner_pid:     12345,
            started_at:    Time.zone.now,
        }

        described_class.create!(defaults.merge(attrs))
    end

    describe ".marked?" do
        it "marker が無ければ false を返す" do
            expect(described_class.marked?(es_index_name)).to eq(false)
        end

        it "marker があれば true を返す" do
            create_index_marker

            expect(described_class.marked?(es_index_name)).to eq(true)
        end
    end

    describe ".with_index_operation_marker!" do
        it "index 操作用 marker を作成し、block の戻り値を返して marker を削除する" do
            marker_inside_block = nil

            result = described_class.with_index_operation_marker!(
                es_index_name,
                operation: "reindex",
            ) do
                marker_inside_block = described_class.find_by(es_index_name: es_index_name)

                "done"
            end

            expect(result).to eq("done")
            expect(marker_inside_block).not_to eq(nil)
            expect(marker_inside_block.operation).to eq("reindex")
            expect(marker_inside_block.owner_token).not_to eq(nil)
            expect(marker_inside_block.owner_pid).to eq(Process.pid)
            expect(marker_inside_block.started_at).not_to eq(nil)
            expect(described_class.find_by(es_index_name: es_index_name)).to eq(nil)
        end

        it "block で例外が出た場合も marker を削除して例外を再送出する" do
            expect do
                described_class.with_index_operation_marker!(
                    es_index_name,
                    operation: "reindex",
                ) do
                    raise RuntimeError, "failed"
                end
            end.to raise_error(RuntimeError, "failed")

            expect(described_class.find_by(es_index_name: es_index_name)).to eq(nil)
        end

        it "owner_token が変わっている marker は削除しない" do
            marker_id = nil

            described_class.with_index_operation_marker!(
                es_index_name,
                operation: "reindex",
            ) do
                marker = described_class.find_by(es_index_name: es_index_name)
                marker_id = marker.id

                marker.update_columns(owner_token: "other-token")
            end

            marker = described_class.find_by(id: marker_id)

            expect(marker).not_to eq(nil)
            expect(marker.owner_token).to eq("other-token")
        end

        it "既存 marker があれば IndexMarkerUnavailable を出す" do
            create_index_marker(operation: "reindex")

            expect do
                described_class.with_index_operation_marker!(
                    es_index_name,
                    operation: "clean_up",
                ) do
                    "not reached"
                end
            end.to raise_error(AreSearch::IndexMarkerUnavailable)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect do
                described_class.with_index_operation_marker!(
                    es_index_name,
                    operation: "reindex",
                ) do
                    "not reached"
                end
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )

            expect(described_class.find_by(es_index_name: es_index_name)).to eq(nil)
        end
    end

    describe ".create_manual!" do
        it "manual marker を作成する" do
            marker = described_class.create_manual!(es_index_name)

            expect(marker.es_index_name).to eq(es_index_name)
            expect(marker.operation).to eq(described_class::MANUAL_OPERATION)
            expect(marker.owner_token).not_to eq(nil)
            expect(marker.started_at).not_to eq(nil)
        end

        it "既存 marker があれば nil を返して上書きしない" do
            existing_marker = create_index_marker(operation: "reindex")

            marker = described_class.create_manual!(es_index_name)

            expect(marker).to eq(nil)
            expect(described_class.find_by(id: existing_marker.id).operation).to eq("reindex")
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            AreSearch.index_operation_enabled = false

            expect do
                described_class.create_manual!(es_index_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end
    end

    describe ".delete_manual!" do
        it "manual marker だけを削除する" do
            marker = create_index_marker(operation: described_class::MANUAL_OPERATION)

            deleted_count = described_class.delete_manual!(es_index_name)

            expect(deleted_count).to eq(1)
            expect(described_class.find_by(id: marker.id)).to eq(nil)
        end

        it "manual 以外の marker は削除しない" do
            marker = create_index_marker(operation: "reindex")

            deleted_count = described_class.delete_manual!(es_index_name)

            expect(deleted_count).to eq(0)
            expect(described_class.find_by(id: marker.id)).not_to eq(nil)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            create_index_marker(operation: described_class::MANUAL_OPERATION)
            AreSearch.index_operation_enabled = false

            expect do
                described_class.delete_manual!(es_index_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end
    end

    describe ".delete_force!" do
        it "operation に関係なく marker を削除する" do
            marker = create_index_marker(operation: "reindex")

            deleted_count = described_class.delete_force!(es_index_name)

            expect(deleted_count).to eq(1)
            expect(described_class.find_by(id: marker.id)).to eq(nil)
        end

        it "index 操作が許可されていない場合は IndexOperationViolation を出す" do
            create_index_marker(operation: "reindex")
            AreSearch.index_operation_enabled = false

            expect do
                described_class.delete_force!(es_index_name)
            end.to raise_error(
                AreSearch::IndexOperationViolation,
                /index 操作が許可されていません/,
            )
        end
    end

    describe "AreSearch manual marker API" do
        it "mark_index! と unmark_index! で manual marker を操作する" do
            marker = AreSearch.mark_index!(es_index_name)

            expect(marker.operation).to eq(described_class::MANUAL_OPERATION)
            expect(described_class.marked?(es_index_name)).to eq(true)

            deleted_count = AreSearch.unmark_index!(es_index_name)

            expect(deleted_count).to eq(1)
            expect(described_class.marked?(es_index_name)).to eq(false)
        end
    end
end
