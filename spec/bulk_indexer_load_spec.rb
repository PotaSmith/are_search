# frozen_string_literal: true

require "spec_helper"

RSpec.describe "BulkIndexer loading" do

    it "are_searchの読み込みでBulkIndexerとIndexTargetの入口を使用できる" do
        expect(defined?(AreSearch::BulkIndexer)).to eq("constant")
        expect(AreSearch::IndexTarget.instance_methods).to include(
            :are_search_bulk_index,
        )
    end
end
