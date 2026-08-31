# frozen_string_literal: true

module AreSearch
    class QueryBuilderBase
        class << self

            def must_params
                [].freeze
            end

            def must_not_params
                [].freeze
            end

            # SearchOptionValidatorでSymbol化済みのオプションから、
            # 必須・禁止オプションの組み合わせが一致するか確認する。
            def match?(valid_options)
                return false if must_params.nil? || must_not_params.nil?
                return false if must_params.empty? && must_not_params.empty?

                must_valid = must_params.all? do |name|
                    valid_options[name].nil? == false
                end

                must_not_valid = must_not_params.all? do |name|
                    valid_options[name].nil?
                end

                must_valid && must_not_valid
            end

            private

            # where をトップレベルfilter内のboolへ変換し、検索対象モデルのfilter条件と並べる。
            def build_bool_base(index_targets, where_opts)
                filter_clauses = []

                where_bool_clause = build_bool_clause(where_opts)
                if where_bool_clause.empty? == false
                    filter_clauses << { bool: where_bool_clause }
                end

                model_filter_clause = AreSearch::SearcherUtils.build_model_filter_clause(index_targets)
                filter_clauses << model_filter_clause

                { filter: filter_clauses }
            end

            # where またはネストしたboolの条件節とminimum_should_matchを Elasticsearch bool 形式へ変換する。
            def build_bool_clause(bool_opts)
                bool_clause = {}
                return bool_clause if bool_opts.nil?

                [:must, :filter, :should, :must_not].each do |clause_type|
                    condition_opts = bool_opts[clause_type]
                    next if condition_opts.nil? || condition_opts.empty?

                    bool_clause[clause_type] = build_condition_clauses(condition_opts)
                end

                minimum_should_match = bool_opts[:minimum_should_match]
                if minimum_should_match.nil? == false
                    bool_clause[:minimum_should_match] = minimum_should_match
                end

                bool_clause
            end

            # Array<condition> を Elasticsearch query句の配列へ変換する。
            def build_condition_clauses(condition_opts)
                clauses = []

                condition_opts.each do |condition_opt|
                    build_condition_clause(clauses, condition_opt)
                end

                clauses
            end

            # condition内の field 条件またはネストしたbool条件をquery句へ追加する。
            def build_condition_clause(clauses, condition_opt)
                condition_opt.each do |condition_name, condition_value|
                    if condition_name == :bool
                        clauses << { bool: build_bool_clause(condition_value) }
                    else
                        build_field_clauses(clauses, condition_name, condition_value)
                    end
                end
            end

            # field内の term / terms / range 条件を Elasticsearch query句へ追加する。
            def build_field_clauses(clauses, field, condition_opt)
                condition_opt.each do |condition_type, value|
                    case condition_type
                    when :term
                        clauses << { term: { field => value } }
                    when :terms
                        clauses << { terms: { field => value } }
                    when :range
                        clauses << { range: { field => value } }
                    else
                        raise ArgumentError, "未知の条件種別です: #{condition_type.inspect}"
                    end
                end
            end
        end
    end
end
