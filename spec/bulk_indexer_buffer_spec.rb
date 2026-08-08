# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::BulkIndexer::Buffer do
    let(:logger) do
        double("logger", fail_count: 0)
    end

    # テスト対象の標準Bufferを返す。
    def build_buffer(
        max_bulk_bytes: 10_000,
        max_bulk_count: 10,
        max_fail_count: 3,
        max_skip_count: 10
    )
        described_class.new(
            max_bulk_bytes: max_bulk_bytes,
            max_bulk_count: max_bulk_count,
            max_fail_count: max_fail_count,
            max_skip_count: max_skip_count,
        )
    end

    # actionとdataをNDJSON化したときのbyte数を返す。
    def serialized_bytesize(action, data)
        action_line = Elasticsearch::API.serializer.dump(action) + "\n"
        data_line = Elasticsearch::API.serializer.dump(data) + "\n"

        action_line.bytesize + data_line.bytesize
    end

    it "sync dataをNDJSONへ変換してIDとcheckpointを返す" do
        buffer = build_buffer
        action = {
            index: {
                _index: "test__articles__default",
                _id:    "1",
            },
        }
        data = {
            id:    1,
            title: "title",
        }

        buffer.append_sync_data("1", action, data)
        result = buffer.take_all

        expected_body =
            Elasticsearch::API.serializer.dump(action) + "\n" +
            Elasticsearch::API.serializer.dump(data) + "\n"

        expect(result).to eq(
            body:               expected_body,
            ids:                ["1"],
            skip_ids:           [],
            fail_id_and_errors: [],
            check_point_id:     "1",
        )
    end

    it "takeは送信待ちだけを返し保留中の1件を次回へ残す" do
        buffer = build_buffer
        first_action = { index: { _index: "index", _id: "1" } }
        second_action = { index: { _index: "index", _id: "2" } }

        buffer.append_sync_data("1", first_action, { id: 1 })
        buffer.append_sync_data("2", second_action, { id: 2 })

        first_result = buffer.take
        second_result = buffer.take_all

        expect(first_result[:ids]).to eq(["1"])
        expect(first_result[:check_point_id]).to eq("1")
        expect(second_result[:ids]).to eq(["2"])
        expect(second_result[:check_point_id]).to eq("2")
    end

    it "skipとfailはbulk bodyへ入れずcheckpoint対象として返す" do
        buffer = build_buffer
        error = RuntimeError.new("data failed")

        buffer.append_no_sync_data("1", :skip, nil)
        buffer.append_no_sync_data("2", :fail, error)
        result = buffer.take_all

        expect(result).to eq(
            body:               "",
            ids:                [],
            skip_ids:           ["1"],
            fail_id_and_errors: [["2", error]],
            check_point_id:     "2",
        )
    end

    it "append_no_sync_dataはfailとskip以外を拒否する" do
        buffer = build_buffer

        expect do
            buffer.append_no_sync_data("1", :index, nil)
        end.to raise_error(AreSearch::Error, "不正な内部操作です")
    end

    it "append_sync_dataはfailとskipをactionとして受け付けない" do
        buffer = build_buffer

        expect do
            buffer.append_sync_data("1", :fail, {})
        end.to raise_error(AreSearch::Error, "不正な内部操作です")
    end

    it "serializerで例外が出たsync dataはdata failとして保持する" do
        buffer = build_buffer
        serializer = double("serializer")
        action = { index: { _index: "index", _id: "1" } }
        error = RuntimeError.new("serialize failed")

        allow(Elasticsearch::API)
            .to receive(:serializer)
            .and_return(serializer)
        allow(serializer)
            .to receive(:dump)
            .with(action)
            .and_raise(error)

        buffer.append_sync_data("1", action, { id: 1 })
        result = buffer.take_all

        expect(result[:body]).to eq("")
        expect(result[:ids]).to eq([])
        expect(result[:fail_id_and_errors]).to eq([["1", error]])
        expect(result[:check_point_id]).to eq("1")
    end

    it "1件だけでmax_bulk_bytesを超えるsync dataはdata failとして保持する" do
        buffer = build_buffer(max_bulk_bytes: 1)

        buffer.append_sync_data(
            "1",
            { index: { _index: "index", _id: "1" } },
            { id: 1 },
        )
        result = buffer.take_all

        expect(result[:body]).to eq("")
        expect(result[:ids]).to eq([])
        expect(result[:fail_id_and_errors].length).to eq(1)
        expect(result[:fail_id_and_errors][0][0]).to eq("1")
        expect(result[:fail_id_and_errors][0][1]).to be_a(AreSearch::Error)
        expect(result[:fail_id_and_errors][0][1].message).to match(
            /max_bulk_bytes を超えるデータがあります: id 1 size \d+ \/ 1/,
        )
        expect(result[:check_point_id]).to eq("1")
    end

    it "送信待ちと保留中を合わせたbyte数が上限を超えるとcapacity overになる" do
        first_action = { index: { _index: "index", _id: "1" } }
        first_data = { id: 1 }
        second_action = { index: { _index: "index", _id: "2" } }
        second_data = { id: 2 }
        first_size = serialized_bytesize(first_action, first_data)
        second_size = serialized_bytesize(second_action, second_data)
        max_bulk_bytes = first_size + second_size - 1
        buffer = build_buffer(max_bulk_bytes: max_bulk_bytes)

        buffer.append_sync_data("1", first_action, first_data)
        buffer.append_sync_data("2", second_action, second_data)

        expect(buffer.capacity_over?(logger)).to eq(true)
    end

    it "送信待ち件数が上限に達するとcapacity overになる" do
        buffer = build_buffer(max_bulk_count: 1)

        buffer.append_sync_data(
            "1",
            { index: { _index: "index", _id: "1" } },
            { id: 1 },
        )
        expect(buffer.capacity_over?(logger)).to eq(false)

        buffer.append_sync_data(
            "2",
            { index: { _index: "index", _id: "2" } },
            { id: 2 },
        )
        expect(buffer.capacity_over?(logger)).to eq(true)
    end

    it "skipまたはdata failの送信待ち件数が上限に達するとcapacity overになる" do
        skip_buffer = build_buffer(max_skip_count: 1)
        fail_buffer = build_buffer(max_skip_count: 1)

        skip_buffer.append_no_sync_data("1", :skip, nil)
        skip_buffer.append_no_sync_data("2", :skip, nil)

        fail_buffer.append_no_sync_data("1", :fail, RuntimeError.new("first"))
        fail_buffer.append_no_sync_data("2", :fail, RuntimeError.new("second"))

        expect(skip_buffer.capacity_over?(logger)).to eq(true)
        expect(fail_buffer.capacity_over?(logger)).to eq(true)
    end

    it "現在の失敗とbulk全件失敗時の合計がmax_fail_countに達するとcapacity overになる" do
        buffer = build_buffer(
            max_bulk_count: 10,
            max_fail_count: 3,
        )
        fail_logger = double("logger", fail_count: 1)

        buffer.append_sync_data(
            "1",
            { index: { _index: "index", _id: "1" } },
            { id: 1 },
        )
        buffer.append_sync_data(
            "2",
            { index: { _index: "index", _id: "2" } },
            { id: 2 },
        )
        expect(buffer.capacity_over?(fail_logger)).to eq(false)

        buffer.append_sync_data(
            "3",
            { index: { _index: "index", _id: "3" } },
            { id: 3 },
        )
        expect(buffer.capacity_over?(fail_logger)).to eq(true)
    end

    it "失敗件数がmax_fail_countを超えると終了する" do
        buffer = build_buffer(max_fail_count: 2)
        fail_logger = double("logger", fail_count: 3)

        expect(buffer.capacity_over?(fail_logger)).to eq(true)
        expect do
            buffer.check_bulk_exit!(fail_logger)
        end.to raise_error(AreSearch::Error, "失敗が多すぎます: max 2")
    end

    it "空のBufferからtakeしてもnilを返す" do
        buffer = build_buffer

        expect(buffer.take).to eq(nil)
        expect(buffer.take_all).to eq(nil)
    end
end
