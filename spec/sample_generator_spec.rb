# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "generators/are_search/sample_generator"

RSpec.describe AreSearch::Generators::SampleGenerator do

    it "rakeとBulkIndexerのサンプルをtmp配下へ生成する" do
        Dir.mktmpdir("are_search_sample_generator") do |destination_root|
            described_class.start([], destination_root: destination_root)

            sample_dir = File.join(
                destination_root,
                "tmp/are_search/sample",
            )

            run_sync_sample_path = File.join(
                sample_dir,
                "are_search_run_sync_requests.rake.sample",
            )
            sync_limit_alert_sample_path = File.join(
                sample_dir,
                "are_search_sync_limit_alert.rake.sample",
            )
            ruby_sample_path = File.join(
                sample_dir,
                "are_search_bulk_index.rb.sample",
            )
            shell_sample_path = File.join(
                sample_dir,
                "are_search_bulk_index.sh.sample",
            )

            expect(File.file?(run_sync_sample_path)).to eq(true)
            expect(File.file?(sync_limit_alert_sample_path)).to eq(true)
            expect(File.file?(ruby_sample_path)).to eq(true)
            expect(File.file?(shell_sample_path)).to eq(true)

            run_sync_sample = File.read(run_sync_sample_path)
            sync_limit_alert_sample = File.read(sync_limit_alert_sample_path)
            ruby_sample = File.read(ruby_sample_path)
            shell_sample = File.read(shell_sample_path)

            expect(run_sync_sample).to include(
                "task :run_sync_requests",
            )
            expect(run_sync_sample).to include(
                "定義されていない sync_stage_name があります",
            )
            expect(sync_limit_alert_sample).to include(
                "task sync_limit_alert: :environment",
            )
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
