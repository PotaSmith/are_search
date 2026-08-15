# frozen_string_literal: true

module AreSearch
    module Generators
        class SampleGenerator < Rails::Generators::Base

            source_root File.expand_path("templates", __dir__)

            # rails generate are_search:sample

            # rake サンプルを、通常ロードされない一時領域へ生成する。
            def copy_rake_sample
                copy_file "are_search_sync_limit_alert.rake",      "tmp/are_search/sample/are_search_sync_limit_alert.rake.sample"
                copy_file "are_search_run_sync_requests.rake",     "tmp/are_search/sample/are_search_run_sync_requests.rake.sample"
                copy_file "are_search_sync_request_boundary.rake", "tmp/are_search/sample/are_search_sync_request_boundary.rake.sample"
            end

            # BulkIndexer の実行用サンプルを、通常ロードされない一時領域へ生成する。
            def copy_bulk_sample
                copy_file "are_search_bulk_index.rb", "tmp/are_search/sample/are_search_bulk_index.rb.sample"
                copy_file "are_search_bulk_index.sh", "tmp/are_search/sample/are_search_bulk_index.sh.sample"
            end
        end
    end
end
