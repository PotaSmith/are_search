# frozen_string_literal: true

module AreSearch
    module Reindexer
        extend self

        def reindex_index_target(index_target)
             AreSearch::IndexManager.es_reindex(
                index_target.are_search_es_index_name,
                index_target.are_search_es_index_settings,
                index_target.are_search_es_mappings,
            ) do |physical_es_index_name|
                bulk_index_target(index_target, physical_es_index_name)
            end
        end

        private

        def bulk_index_target(index_target, physical_es_index_name)
            total      = index_target.model_class.count
            bar        = ProgressBar.new(total) unless total == 0
            failed_ids = []

            index_target.model_class.find_in_batches(batch_size: 500) do |batch|
                body = build_bulk_body(index_target, batch, physical_es_index_name)
                bar&.increment!(batch.size)

                next if body.empty?

                response = AreSearch.client.bulk(body: body)

                collect_bulk_errors(response, failed_ids)
            end

            if failed_ids.any?
                AreSearch.logger.error { "[AreSearch] reindex completed with #{failed_ids.size} failures" }
            end

            failed_ids
        end

        def build_bulk_body(index_target, batch, physical_es_index_name)
            body = []

            batch.each do |record|
                next if record.are_search_es_indexable?(index_target.target_name) != true

                body << { index: { _index: physical_es_index_name, _id: record.id.to_s } }
                body << record.are_search_es_data(index_target.target_name)
            end

            body
        end

        def collect_bulk_errors(response, failed_ids)
            return unless response["errors"]

            response["items"].each do |item|
                op = item["index"] || item["create"] || item["update"] || item["delete"]
                next unless op&.dig("error")

                failed_ids << op["_id"]
                AreSearch.logger.error { "[AreSearch] bulk index failed: id=#{op["_id"]} error=#{op["error"].inspect}" }
            end
        end
    end
end
