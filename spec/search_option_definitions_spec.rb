# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Searcher::OPTION_DEFINITIONS" do
    it "現行定義を明示指定してDefinitionCheckerを通過する" do
        definitions = AreSearch::Searcher::OPTION_DEFINITIONS

        result = AreSearch::SearchOptionDefinitionChecker
            .validate_option_definitions!(definitions)

        expect(result).to eq(true)
    end

    it "デフォルト引数でも現行定義を検査する" do
        result = AreSearch::SearchOptionDefinitionChecker
            .validate_option_definitions!

        expect(result).to eq(true)
    end
end
