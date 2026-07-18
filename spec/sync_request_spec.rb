# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SyncRequest do
    let(:base_attrs) do
        {
            ar_model_class_name: "Article",
            index_target_name:   "default",
            ar_instance_key:     "123",
            es_index_name:       "test_articles",
            request_sequence:    10,
            request_sequence_at: Time.zone.now,
            retry_count:         0,
            last_error:          nil,
        }
    end
    let(:unique_by) { [:es_index_name, :ar_model_class_name, :ar_instance_key] }
    let(:base_key) do
        {
            es_index_name:    "test_articles",
            ar_instance_key:  "123",
        }
    end

    describe ".next_request_sequence" do
        it "設定されたproviderへ採番を委譲する" do
            provider_class = class_double(
                "RequestSequenceProvider",
                next_value: 123,
            )

            allow(AreSearch)
                .to receive(:request_sequence_provider)
                .and_return(provider_class)

            expect(described_class.next_request_sequence).to eq(123)
        end
    end

    describe ".upsert" do
        it "実際にDBへレコードを1件登録する" do
            described_class.upsert(base_attrs, unique_by: unique_by)

            expect(described_class.count).to eq(1)

            record = described_class.find_by(base_key)
            expect(record.ar_instance_key).to eq("123")
            expect(record.es_index_name).to eq("test_articles")
            expect(record.request_sequence).to eq(10)
            expect(record.retry_count).to eq(0)
            expect(record.last_error).to be_nil
        end

        it "同一キーで2回 upsert しても重複しない" do
            described_class.upsert(base_attrs, unique_by: unique_by)
            described_class.upsert(base_attrs, unique_by: unique_by)

            expect(described_class.count).to eq(1)
        end

        it "エラー状態のレコードに対して upsert すると retry_count と last_error がリセットされる" do
            described_class.upsert(base_attrs, unique_by: unique_by)

            described_class.find_by(base_key).update(
                retry_count: 3,
                last_error:  "connection refused",
            )

            described_class.upsert(
                base_attrs.merge(request_sequence: 11),
                unique_by: unique_by,
            )

            record = described_class.find_by(base_key)
            expect(record.request_sequence).to eq(11)
            expect(record.retry_count).to eq(0)
            expect(record.last_error).to be_nil
        end

        it "異なるキーのレコードは別々に登録される" do
            described_class.upsert(base_attrs, unique_by: unique_by)
            described_class.upsert(
                base_attrs.merge(ar_instance_key: "456", request_sequence: 11),
                unique_by: unique_by,
            )

            expect(described_class.count).to eq(2)
        end
    end

    describe "#update" do
        it "retry_count と last_error を更新できる" do
            described_class.upsert(base_attrs, unique_by: unique_by)

            described_class.find_by(base_key).update(
                retry_count: 5,
                last_error:  "timeout",
            )

            record = described_class.find_by(base_key)
            expect(record.retry_count).to eq(5)
            expect(record.last_error).to eq("timeout")
        end
    end
end
