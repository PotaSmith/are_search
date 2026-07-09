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
    # highlights_html(record, target_name, tag: 'em', attr: nil)
    #   ハイライトされたフラグメントのフラット配列を返す。
    #   ヒットなし・highlight オプション未指定の場合は []。
    #   tag  : マッチ箇所を囲むHTMLタグ名 (default: 'em')
    #   attr : タグに付与する属性文字列 (例: 'class="hl"', default: nil)
    #
    # highlights_source(record, target_name)
    #   _source をそのまま { field: value } の形で返す。
    #   ヒットなし・highlight オプション未指定の場合は {}。
    #
    # @param highlights [Hash{String => {fragments: Array<String>, source: Hash{Symbol => Object}}}]
    #
    class SearchResult
        HIGHLIGHT_PRE_TAG    = "<em>"
        HIGHLIGHT_POST_TAG   = "</em>"
        HIGHLIGHT_PRE_TAGS   = [HIGHLIGHT_PRE_TAG].freeze
        HIGHLIGHT_POST_TAGS  = [HIGHLIGHT_POST_TAG].freeze

        attr_reader :records_with_target_names, :records, :aggs, :raw_response

        def initialize(records_with_target_names, records, aggs, highlights = {}, raw_response: nil)
            @records_with_target_names  = records_with_target_names
            @records                    = records
            @aggs                       = aggs
            @highlights                 = highlights
            @raw_response               = raw_response
        end

        def highlights_html(record, target_name, tag: "em", class_name: nil)
            data = @highlights[composite_key_by_record(record, target_name)]
            return [] unless data

            fragments = data[:fragments]
            return [] if fragments.empty?

            tag_name = tag.to_s
            validate_highlight_tag!(tag_name)

            open_tag = build_open_highlight_tag(tag_name, class_name)
            close_tag = "</#{tag_name}>"

            fragments.map do |f|
                f.gsub(HIGHLIGHT_PRE_TAG, open_tag)
                 .gsub(HIGHLIGHT_POST_TAG, close_tag)
            end
        end

        def highlights_source(record, target_name)
            data = @highlights[composite_key_by_record(record, target_name)]
            return {} unless data

            data[:source]
        end

        private

        def composite_key_by_record(record, target_name)
            index_target = record.class.are_search_index_target(target_name)
            return "" if index_target.nil?

            index_target.are_search_es_composite_key(record.id)
        end

        def validate_highlight_tag!(tag_name)
            return if tag_name.match?(/\A[a-z][a-z0-9-]*\z/i)

            raise ArgumentError, "tag は HTML タグ名で指定してください: #{tag_name.inspect}"
        end

        def validate_highlight_class_name!(class_name)
            return if class_name.to_s.match?(/\A[a-z0-9_\- ]+\z/i)

            raise ArgumentError, "class_name は CSS class 名で指定してください: #{class_name.inspect}"
        end

        def build_open_highlight_tag(tag_name, class_name)
            return "<#{tag_name}>" if class_name.blank?

            validate_highlight_class_name!(class_name)

            escaped_class_name = escape_html_attr(class_name.to_s)

            "<#{tag_name} class=\"#{escaped_class_name}\">"
        end

        HTML_ESCAPE_MAP = {
            "&" => "&amp;",
            '"' => "&quot;",
            "<" => "&lt;",
            ">" => "&gt;",
        }.freeze

        def escape_html_attr(value)
            value.to_s.gsub(/[&"<>]/) do |char|
                HTML_ESCAPE_MAP[char]
            end
        end
    end
end
