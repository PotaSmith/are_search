# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::DatabaseSpecific do
    describe ".next_request_sequence" do
        it "継承クラスが実装しなければ例外にする" do
            database_specific_class = Class.new(described_class)

            expect do
                database_specific_class.next_request_sequence
            end.to raise_error(
                NotImplementedError,
                /next_request_sequence を実装してください/,
            )
        end
    end

    describe ".upsert" do
        it "継承クラスが実装しなければ例外にする" do
            database_specific_class = Class.new(described_class)

            expect do
                database_specific_class.upsert(
                    ar_model_class_name: "Article",
                    index_target_name:   :default,
                    ar_instance_key:     "123",
                    es_index_name:       "test__articles__default",
                    request_sequence:    42,
                    request_sequence_at: Time.zone.now,
                )
            end.to raise_error(
                NotImplementedError,
                /upsert を実装してください/,
            )
        end
    end
end

RSpec.describe AreSearch::PostgreSQLDatabaseSpecific do
    describe ".next_request_sequence" do
        it "PostgreSQL sequence の次の値を整数で返す" do
            connection = ActiveRecord::Base.connection

            expect(connection)
                .to receive(:select_value)
                .with(described_class::REQUEST_SEQUENCE_SQL)
                .and_return("123")

            expect(described_class.next_request_sequence).to eq(123)
        end
    end

    describe ".upsert" do
        it "同期要求を一意キーでupsertする" do
            request_sequence_at = Time.zone.now

            expect(AreSearch::SyncRequest)
                .to receive(:upsert)
                .with(
                    {
                        ar_model_class_name: "Article",
                        index_target_name:   :default,
                        ar_instance_key:     "123",
                        es_index_name:       "test__articles__default",
                        request_sequence:    42,
                        request_sequence_at: request_sequence_at,
                        retry_count:         0,
                        last_error:           nil,
                    },
                    unique_by: [:es_index_name, :ar_model_class_name, :ar_instance_key],
                )

            described_class.upsert(
                ar_model_class_name: "Article",
                index_target_name:   :default,
                ar_instance_key:     "123",
                es_index_name:       "test__articles__default",
                request_sequence:    42,
                request_sequence_at: request_sequence_at,
            )
        end
    end
end
