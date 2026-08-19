# frozen_string_literal: true

module AreSearch
    class PaginatedCollection < Array

        # ページネーション結果コレクション

        # Kaminari paginate / 前後ページ系 helper の使用を想定
        attr_reader :page, :per_page
        alias current_page page # Kaminari will_paginate 互換
        alias limit_value per_page # Kaminari paginate / page_entries_info 互換

        # Kaminari page_entries_info の使用を想定
        attr_reader :total_count

        attr_reader :es_total_count, :hits_count, :max_result_window, :pagination_total_count
        alias total_entries total_count # will_paginate 互換

        # 検索で得た件数情報を保持し、ページング用件数を組み立てる。
        def initialize(
            records,
            page:,
            per_page:,
            es_total_count:,
            hits_count:,
            max_result_window:
        )
            raise ArgumentError, "per_page は1以上で指定してください" if per_page.to_i < 1
            super(records)

            # 検索パラメータ
            @page = page.to_i
            @per_page = per_page.to_i

            # 検索結果
            @es_total_count = es_total_count.to_i
            @hits_count = hits_count.to_i
            @max_result_window = max_result_window.to_i

            # これ以降が計算

            # 補正値
            dropped_count = (hits_count - records.size)

            # 補正込の es内データ件数
            @total_count = @es_total_count - dropped_count

            # 補正込の esが検索結果として返却した総数
            @pagination_total_count = [es_total_count, max_result_window].min - dropped_count
        end

        def dup
            PaginatedCollection.new(
                to_a.dup,
                page:              @page,
                per_page:          @per_page,
                es_total_count:    @es_total_count,
                hits_count:        @hits_count,
                max_result_window: @max_result_window,
            )
        end

        def over_max_result_window?
            es_total_count > max_result_window && (offset + hits_count) >= max_result_window
        end

        #
        # page, per_page は検索パラメータそのまま
        # 検索パラメータチェックにより数値保証はある
        # page 省略時は 1
        # per_page 省略時は 25
        #

        # Kaminari paginate / page_entries_info の使用を想定
        def total_pages
            return 0 if @pagination_total_count == 0

            (@pagination_total_count.to_f / @per_page).ceil
        end

        def first_page?
            @page <= 1
        end

        def last_page?
            @page == total_pages
        end

        # will_paginate互換
        def out_of_range?
            @page < 1 || @page > total_pages
        end
        alias out_of_bounds? out_of_range? # will_paginate互換

        # Kaminari 前後ページ系 helper の使用を想定
        def previous_page
            return nil if first_page?
            return nil if out_of_range?

            @page - 1
        end
        alias prev_page previous_page # Kaminari 前ページ系 helper 互換

        # Kaminari 次ページ系 helper の使用を想定
        def next_page
            return nil if last_page?
            return nil if out_of_range?

            @page + 1
        end

        # Kaminari page_entries_info の使用を想定
        def offset
            (@page - 1) * @per_page
        end
        alias offset_value offset # Kaminari page_entries_info 互換

        # Kaminari page_entries_info の使用を想定
        def entry_name(count:)
            "entry"
        end

    end

    class SearchResult

        # 検索結果オブジェクト
        #
        # records_with_hit
        #   ActiveRecord のレコードと、対応する Elasticsearch の
        #   _index, _id, _source、fields、highlight、index_target_name 等の情報を検索順で返す。
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
        #   :ok は検索実行済み、:params_invalid と :index_not_found と :search_fail は検索未実行。
        #
        # @param records [PaginatedCollection]
        # @param records_with_hit [Array]
        # @param aggs [Hash{Symbol => Array}]
        # @param str_key_aggs [Hash{Symbol => Array}]
        # @param status [Symbol]

        STATUS_OK = :ok
        STATUS_PARAMS_INVALID  = :params_invalid
        STATUS_INDEX_NOT_FOUND = :index_not_found
        STATUS_SEARCH_FAIL     = :search_fail

        STATUSES = [
            STATUS_OK,
            STATUS_PARAMS_INVALID,
            STATUS_INDEX_NOT_FOUND,
            STATUS_SEARCH_FAIL,
        ].freeze

        attr_reader :status,
            :records,
            :records_with_hit,
            :raw_response

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

            @status = status
            @records = records
            @records_with_hit = records_with_hit
            @aggs = aggs
            @str_key_aggs = str_key_aggs
            @raw_response = raw_response
        end

        # 集計名を指定した場合は表示用キーの簡易結果を返し、省略時は内部キーの全体を返す。
        def aggs(name = nil)
            return @aggs if name.nil?

            @str_key_aggs.fetch(name.to_sym, [])
        end

        def max_result_window
            @records.max_result_window
        end

        def over_max_result_window?
            @records.over_max_result_window?
        end
    end
end
