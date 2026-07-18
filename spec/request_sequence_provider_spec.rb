# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::RequestSequenceProvider do
    describe ".next_value" do
        it "継承クラスが実装しなければ例外にする" do
            provider_class = Class.new(described_class)

            expect do
                provider_class.next_value
            end.to raise_error(
                NotImplementedError,
                /next_value を実装してください/,
            )
        end
    end
end

RSpec.describe AreSearch::PostgreSQLRequestSequenceProvider do
    describe ".next_value" do
        it "PostgreSQL sequence の次の値を整数で返す" do
            connection = ActiveRecord::Base.connection

            expect(connection)
                .to receive(:select_value)
                .with(described_class::REQUEST_SEQUENCE_SQL)
                .and_return("123")

            expect(described_class.next_value).to eq(123)
        end
    end
end
