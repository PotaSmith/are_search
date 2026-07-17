# frozen_string_literal: true

module AreSearch
    # ページネーション結果コレクション
    class PaginatedCollection < Array
        attr_reader :current_page, :per_page, :total_count, :es_total_count

        def initialize(records, current_page:, per_page:, total_count:, es_total_count: nil)
            raise ArgumentError, "per_page は1以上で指定してください" if per_page.to_i < 1

            super(records)
            @current_page   = current_page.to_i
            @per_page       = per_page.to_i
            @total_count    = total_count.to_i
            @es_total_count = es_total_count.nil? ? @total_count : es_total_count.to_i
        end

        def dup
            PaginatedCollection.new(
                to_a.dup,
                current_page:   @current_page,
                per_page:       @per_page,
                total_count:    @total_count,
                es_total_count: @es_total_count,
            )
        end

        def total_pages
            return 0 if @total_count == 0

            (@total_count.to_f / @per_page).ceil
        end

        def first_page?
            @current_page <= 1
        end

        def last_page?
            @current_page == total_pages
        end

        def out_of_range?
            @current_page < 1 || @current_page > total_pages
        end

        def previous_page
            return nil if first_page?
            return nil if out_of_range?

            @current_page - 1
        end

        def next_page
            return nil if last_page?
            return nil if out_of_range?

            @current_page + 1
        end

        def offset
            (@current_page - 1) * @per_page
        end

        def entry_name(count:)
            "entry"
        end

        alias limit_value    per_page
        alias total_entries  total_count
        alias out_of_bounds? out_of_range? # will_paginate互換
        alias prev_page      previous_page # kaminari互換
        alias offset_value   offset        # kaminari互換
    end

    # 検索結果オブジェクト
    #
    # highlights(record, target_name)
    #   Elasticsearch が返したフィールド別 highlight Hash を返す。
    #   対象 hit にハイライトが無い場合は {}。
    #
    # hit_source(record, target_name)
    #   検索時に返された _source を { field: value } の形で返す。
    #   対象 hit が無い場合は {}。highlight の指定有無には依存しない。
    #
    # @param hit_sources [Hash{String => Hash{Symbol => Object}}]
    # @param highlights [Hash{String => Hash{Symbol => Array<String>}}]
    #
    class SearchResult

        attr_reader :records_with_target_names, :records, :aggs, :raw_response, :params_invalid

        def initialize(records_with_target_names, records, aggs, hit_sources, highlights = {}, raw_response: nil, params_invalid: false)
            @records_with_target_names  = records_with_target_names
            @records                    = records
            @aggs                       = aggs
            @highlights                 = highlights
            @hit_sources                = hit_sources
            @raw_response               = raw_response
            @params_invalid             = params_invalid
        end

        # Elasticsearch が返したフィールド別 highlight をそのまま返す。
        def highlights(record, target_name)
            result = @highlights[composite_key_by_record(record, target_name)]
            return {} if result.nil?

            result
        end

        # 確認用で普通は使わない
        def hit_source(record, target_name)
            source = @hit_sources[composite_key_by_record(record, target_name)]
            return {} if source.nil?

            source
        end

        private

        def composite_key_by_record(record, target_name)
            index_target = record.class.are_search_index_target(target_name)
            return "" if index_target.nil?

            index_target.are_search_es_composite_key(record.id)
        end

    end
end
