# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchParamPolicy do
    describe ".valid?" do
        it "基底policyは継承先でvalid?を実装するよう要求する" do
            expect do
                described_class.valid?("query_string", "value")
            end.to raise_error(
                NotImplementedError,
                "AreSearch::SearchParamPolicy.valid? を実装してください",
            )
        end
    end
end

RSpec.describe AreSearch::ParamLengthSearchParamPolicy do
    describe ".valid?" do
        it "query_stringは2048文字までtrueを返して2049文字でfalseを返す" do
            expect(described_class.valid?("query_string", "a" * 2048)).to eq(true)
            expect(described_class.valid?("query_string", "a" * 2049)).to eq(false)
        end

        it "where系のterm値とterms、range全体は256文字までtrueを返して257文字でfalseを返す" do
            [:where, :where_not, :where_or].each do |key|
                expect(described_class.valid?("#{key}.term", "a" * 256)).to eq(true)
                expect(described_class.valid?("#{key}.term", "a" * 257)).to eq(false)

                terms_base_length = ["", "b"].to_s.length
                valid_terms = ["a" * (256 - terms_base_length), "b"]
                invalid_terms = ["a" * (257 - terms_base_length), "b"]

                expect(described_class.valid?("#{key}.terms", valid_terms)).to eq(true)
                expect(described_class.valid?("#{key}.terms", invalid_terms)).to eq(false)

                range_base_length = { gte: "", lte: "b" }.to_s.length
                valid_range = { gte: "a" * (256 - range_base_length), lte: "b" }
                invalid_range = { gte: "a" * (257 - range_base_length), lte: "b" }

                expect(described_class.valid?("#{key}.range", valid_range)).to eq(true)
                expect(described_class.valid?("#{key}.range", invalid_range)).to eq(false)
            end
        end
    end

    describe ".validate!" do
        it "query_stringは2048文字まで許可して2049文字を拒否する" do
            expect do
                described_class.validate!(
                    queries: [
                        {
                            query_string: "a" * 2048,
                        },
                    ],
                )
            end.not_to raise_error

            expect do
                described_class.validate!(
                    queries: [
                        {
                            query_string: "a" * 2049,
                        },
                    ],
                )
            end.to raise_error(AreSearch::InvalidSearchOption)
        end

        it "where系Hash形式はterm値とterms、range全体の256文字境界を検査する" do
            terms_base_length = ["", "b"].to_s.length
            range_base_length = { gte: "", lte: "b" }.to_s.length

            valid_conditions = [
                { status: { term: "a" * 256 } },
                { status: { terms: ["a" * (256 - terms_base_length), "b"] } },
                { status: { range: { gte: "a" * (256 - range_base_length), lte: "b" } } },
            ]
            invalid_conditions = [
                { status: { term: "a" * 257 } },
                { status: { terms: ["a" * (257 - terms_base_length), "b"] } },
                { status: { range: { gte: "a" * (257 - range_base_length), lte: "b" } } },
            ]

            [:where, :where_not, :where_or].each do |key|
                valid_conditions.each do |condition|
                    expect do
                        described_class.validate!({ key => condition })
                    end.not_to raise_error
                end

                invalid_conditions.each do |condition|
                    expect do
                        described_class.validate!({ key => condition })
                    end.to raise_error(AreSearch::InvalidSearchOption)
                end
            end
        end

        it "where系Array形式でもterm値とterms、range全体へ文字数制限を適用する" do
            terms_base_length = ["", "b"].to_s.length
            range_base_length = { gte: "", lte: "b" }.to_s.length

            invalid_conditions = [
                { status: { term: "a" * 257 } },
                { status: { terms: ["a" * (257 - terms_base_length), "b"] } },
                { status: { range: { gte: "a" * (257 - range_base_length), lte: "b" } } },
            ]

            [:where, :where_not, :where_or].each do |key|
                invalid_conditions.each do |condition|
                    expect do
                        described_class.validate!({ key => [condition] })
                    end.to raise_error(AreSearch::InvalidSearchOption)
                end
            end
        end

        it "nilのオプションがあっても後続の検索値を検査する" do
            expect do
                described_class.validate!(
                    queries: nil,
                    where: {
                        status: {
                            term: "a" * 257,
                        },
                    },
                )
            end.to raise_error(AreSearch::InvalidSearchOption)

            expect do
                described_class.validate!(
                    where: nil,
                    where_or: {
                        status: {
                            term: "a" * 257,
                        },
                    },
                )
            end.to raise_error(AreSearch::InvalidSearchOption)
        end
    end
end
