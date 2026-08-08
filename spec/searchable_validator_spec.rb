# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchableValidator do
    it "利用側定義名の検査を公開しない" do
        expect(described_class.respond_to?(:valid_definition_name?)).to eq(false)
        expect(described_class.respond_to?(:definition_name_format_description)).to eq(false)
    end
end
