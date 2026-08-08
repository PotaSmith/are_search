# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "generators/are_search/sample_generator"

RSpec.describe AreSearch::Generators::SampleGenerator do

    it "BulkIndexerのRubyとshellサンプルをtmp配下へ生成する" do
        Dir.mktmpdir("are_search_bulk_sample_generator") do |destination_root|
            described_class.start([], destination_root: destination_root)

            ruby_sample_path = File.join(
                destination_root,
                "tmp/are_search/sample/are_search_bulk_index.rb.sample",
            )
            shell_sample_path = File.join(
                destination_root,
                "tmp/are_search/sample/are_search_bulk_index.sh.sample",
            )

            expect(File.file?(ruby_sample_path)).to eq(true)
            expect(File.file?(shell_sample_path)).to eq(true)

            ruby_sample = File.read(ruby_sample_path)
            shell_sample = File.read(shell_sample_path)

            expect(ruby_sample).to include(
                'ENV.fetch("ARE_SEARCH_BULK_RESULT_DIR")',
            )
            expect(ruby_sample).to include(
                "index_target.are_search_bulk_index(",
            )
            expect(shell_sample).to include(
                'exec bundle exec rails runner "$RUBY_SCRIPT"',
            )
            expect(shell_sample).to include(
                'RESULT_DIR="/path/to/persistent/are_search/bulk/article_new_version"',
            )

            max_bulk_count = ruby_sample.match(
                /max_bulk_count\s*=\s*(\d+)/,
            )[1].to_i
            max_fail_count = ruby_sample.match(
                /max_fail_count\s*=\s*(\d+)/,
            )[1].to_i

            expect(max_bulk_count).to be <= max_fail_count
            expect(max_fail_count).to be <= (
                AreSearch::BulkIndexer::MAX_RECOVER_COUNT / 2
            )
        end
    end
end
