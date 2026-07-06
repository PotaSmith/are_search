# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SyncJob, "extra cases" do
    it "model constantize の失敗は握りつぶさない" do
        expect do
            described_class.new.perform(
                "app_test",
                "MissingArticle",
                :default,
                "123",
                "test_articles_default",
                "token-1",
            )
        end.to raise_error(NameError)
    end
end
