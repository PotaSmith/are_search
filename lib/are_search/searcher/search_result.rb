# frozen_string_literal: true

module AreSearch
    class PaginatedCollection < Array

        # ページネーション結果コレクション

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

    class SearchResult

        # 検索結果オブジェクト
        #
        # records_with_hit
        #   ActiveRecord のレコードと、対応する Elasticsearch の
        #   _index, _id, _source、fields、highlight、target_name 等の情報を検索順で返す。
        #   フィールド名は Symbolで、先頭の "_" は削除し index, source, fields, highlightのように変更。
        #   _source、fields、highlightは対象 hit に値が無い場合は空 Hash。
        #
        # aggs(name = nil)
        #   集計名を指定した場合は、key_as_string を優先した簡易集計結果を返す。
        #   key がある bucket は [key, doc_count]、key がない bucket は doc_count。
        #   対象 aggregation が無い場合は []。
        #   集計名を省略した場合は、key を使った簡易集計結果全体を返す。
        #
        # status
        #   検索の終了状態を返す。
        #   :ok は検索実行済み、:params_invalid と :index_not_found は検索未実行。
        #
        # @param records [PaginatedCollection]
        # @param records_with_hit [Array]
        # @param aggs [Hash{Symbol => Array}]
        # @param str_key_aggs [Hash{Symbol => Array}]
        # @param status [Symbol]

        STATUS_OK = :ok
        STATUS_PARAMS_INVALID  = :params_invalid
        STATUS_INDEX_NOT_FOUND = :index_not_found

        STATUSES = [
            STATUS_OK,
            STATUS_PARAMS_INVALID,
            STATUS_INDEX_NOT_FOUND,
        ].freeze

        attr_reader :records,
            :records_with_hit,
            :raw_response,
            :status

        # 検索結果として定義された終了状態だけを受け付ける。
        def initialize(
            records,
            records_with_hit,
            aggs,
            str_key_aggs,
            raw_response: nil,
            status: STATUS_OK
        )
            unless STATUSES.include?(status)
                raise ArgumentError, "未知の検索結果statusです: #{status.inspect}"
            end

            @records = records
            @records_with_hit = records_with_hit
            @aggs = aggs
            @str_key_aggs = str_key_aggs
            @raw_response = raw_response
            @status = status
        end

        # 集計名を指定した場合は表示用キーの簡易結果を返し、省略時は内部キーの全体を返す。
        def aggs(name = nil)
            return @aggs if name.nil?

            @str_key_aggs.fetch(name.to_sym, [])
        end
    end
end
