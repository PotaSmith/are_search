# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchUtils do
    let(:helper_class) do
        Class.new do
            include AreSearch::SearchUtils
        end
    end
    let(:helper) { helper_class.new }
    let(:valid_fields) do
        [
            :title,
            :status,
            :published_at,
            :category_id,
            :field1,
        ]
    end

    describe "field typo check" do
        it "simple field name の未定義だけを typo 候補にする" do
            fields = [
                :title,
                :statuz,
                :published_at,
                :_score,
                :_field,
                :field_,
                :"title.keyword",
                :fooBar,
                :Title,
                :field1,
            ]

            invalid = helper.invalid_typo_checkable_fields(fields, valid_fields)

            expect(invalid).to eq([:statuz])
        end

        it "where では typo 候補だけを未定義フィールドとして扱う" do
            expect do
                helper.validate_where!(
                    { filter_clauses: [] },
                    { statuz: "published" },
                    valid_fields,
                    caller_name: :multi_search,
                )
            end.to raise_error(ArgumentError, /:where に未定義のフィールドがあります: \[:statuz\]/)

            ctx = { filter_clauses: [] }

            helper.validate_where!(
                ctx,
                {
                    :_field => "x",
                    :field_ => "x",
                    :"title.keyword" => "x",
                    :fooBar => "x",
                },
                valid_fields,
                caller_name: :multi_search,
            )

            expect(ctx[:filter_clauses]).to eq([
                { term: { :_field => "x" } },
                { term: { :field_ => "x" } },
                { term: { :"title.keyword" => "x" } },
                { term: { :fooBar => "x" } },
            ])
        end

        it "sort では _ 始まり、_ 終わり、ドット付き、大文字混じりを ES 側判断に逃がす" do
            ctx = { sort: {} }

            helper.validate_sort!(
                ctx,
                [
                    { _score: :desc },
                    { field_: :asc },
                    { :"title.keyword" => :asc },
                    { fooBar: :desc },
                ],
                valid_fields,
                caller_name: :multi_search,
            )

            expect(ctx[:sort]).to eq([
                { _score: :desc },
                { field_: :asc },
                { :"title.keyword" => :asc },
                { fooBar: :desc },
            ])
        end
    end
end
