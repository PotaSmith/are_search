# frozen_string_literal: true

module AreSearch
    class SearchParamValidator
        class << self
            # index targetとモデルから検査用contextを作成し、
            # SearchOptionValidatorで検索オプションを検査・正規化する。
            # 複数オプション間の関係だけは、このクラスで追加検査する。
            def validate(index_targets, models, **dirty_options)
                context = build_search_option_context(
                    index_targets,
                    models,
                )

                options = AreSearch::SearchOptionValidator.validate(
                    dirty_options,
                    AreSearch::Searcher::OPTION_DEFINITIONS,
                    context,
                )

                validate_option_relations!(options)

                options
            end

            private

            # SearchOptionValidatorが検索対象外部情報を検査できるよう、
            # targetごとのフィールド情報から以下の集合を作成する。
            #
            # any_fields:
            #   1つ以上のtargetに存在するフィールド。
            #
            # all_fields:
            #   すべてのtargetに存在するフィールド。
            #
            # any_text_without_non_text_fields:
            #   1つ以上のtargetでtext型として定義され、
            #   ほかのtargetで同名フィールドが非text型として定義されていないフィールド。
            #   同名フィールドが未定義のtargetは許容する。
            #
            # all_valid_text_fields:
            #   すべてのtargetでtext型として定義されているフィールド。
            #
            # any_text_or_keyword_without_other_type_fields:
            #   1つ以上のtargetでtext型またはkeyword型として定義され、
            #   ほかのtargetで同名フィールドが別の型として定義されていないフィールド。
            #   同名フィールドが未定義のtargetは許容する。
            #
            # all_valid_text_or_keyword_fields:
            #   すべてのtargetでtext型またはkeyword型として定義されているフィールド。
            #
            # any_non_text_without_text_fields:
            #   1つ以上のtargetで非text型として定義され、
            #   ほかのtargetで同名フィールドがtext型として定義されていないフィールド。
            #   同名フィールドが未定義のtargetは許容する。
            #
            # all_valid_non_text_fields:
            #   すべてのtargetで非text型として定義されているフィールド。
            def build_search_option_context(index_targets, models)
                target_field_contexts = collect_target_field_contexts(index_targets)

                {
                    models: models,
                    any_fields: collect_union_fields(
                        target_field_contexts,
                        :fields,
                    ),
                    all_fields: collect_intersection_fields(
                        target_field_contexts,
                        :fields,
                    ),
                    any_text_without_non_text_fields: collect_exclusive_union_fields(
                        target_field_contexts,
                        :text_fields,
                        :non_text_fields,
                    ),
                    all_valid_text_fields: collect_intersection_fields(
                        target_field_contexts,
                        :text_fields,
                    ),
                    any_text_or_keyword_without_other_type_fields: collect_exclusive_union_fields(
                        target_field_contexts,
                        :text_or_keyword_fields,
                        :other_type_fields,
                    ),
                    all_valid_text_or_keyword_fields: collect_intersection_fields(
                        target_field_contexts,
                        :text_or_keyword_fields,
                    ),
                    any_non_text_without_text_fields: collect_exclusive_union_fields(
                        target_field_contexts,
                        :non_text_fields,
                        :text_fields,
                    ),
                    all_valid_non_text_fields: collect_intersection_fields(
                        target_field_contexts,
                        :non_text_fields,
                    ),
                }
            end

            # index targetごとに全フィールド・textフィールド・非textフィールドを収集する。
            def collect_target_field_contexts(index_targets)
                target_field_contexts = []

                index_targets.each do |index_target|
                    fields = collect_target_fields(index_target)
                    text_fields = collect_target_text_fields(index_target)
                    text_or_keyword_fields = collect_target_text_or_keyword_fields(index_target)

                    target_field_contexts << {
                        fields: fields,
                        text_fields: text_fields,
                        text_or_keyword_fields: text_or_keyword_fields,
                        non_text_fields: fields - text_fields,
                        other_type_fields: fields - text_or_keyword_fields,
                    }
                end

                target_field_contexts
            end

            # 1つのindex targetから検索オプションで指定可能な全フィールド名を収集する。
            def collect_target_fields(index_target)
                mappings = index_target.are_search_es_mappings
                result = []

                collect_mapping_field_names(
                    result,
                    mappings[:properties],
                )
                collect_mapping_field_names(
                    result,
                    mappings[:runtime],
                )

                result.uniq
            end

            # 1つのindex targetからtext型またはkeyword型のフィールド名を収集する。
            def collect_target_text_or_keyword_fields(index_target)
                mappings = index_target.are_search_es_mappings
                result = []

                collect_mapping_text_or_keyword_field_names(
                    result,
                    mappings[:properties],
                )
                collect_mapping_text_or_keyword_field_names(
                    result,
                    mappings[:runtime],
                )

                result.uniq
            end

            # 1つのindex targetからtext型フィールド名を収集する。
            def collect_target_text_fields(index_target)
                mappings = index_target.are_search_es_mappings
                result = []

                collect_mapping_text_field_names(
                    result,
                    mappings[:properties],
                )
                collect_mapping_text_field_names(
                    result,
                    mappings[:runtime],
                )

                result.uniq
            end

            # mappings内のフィールド名をSymbolへ統一して追加する。
            def collect_mapping_field_names(result, mapping_fields)
                return if mapping_fields.instance_of?(Hash) == false

                mapping_fields.each_key do |field_name|
                    result << field_name.to_s.to_sym
                end
            end

            # mappings内のtext型フィールド名をSymbolへ統一して追加する。
            def collect_mapping_text_field_names(result, mapping_fields)
                return if mapping_fields.instance_of?(Hash) == false

                mapping_fields.each do |field_name, field_options|
                    next if field_options.instance_of?(Hash) == false
                    next if field_options[:type].to_s != "text"

                    result << field_name.to_s.to_sym
                end
            end

            # mappings内のtext型またはkeyword型フィールド名をSymbolへ統一して追加する。
            def collect_mapping_text_or_keyword_field_names(result, mapping_fields)
                return if mapping_fields.instance_of?(Hash) == false

                mapping_fields.each do |field_name, field_options|
                    next if field_options.instance_of?(Hash) == false

                    field_type = field_options[:type].to_s
                    next if field_type != "text" && field_type != "keyword"

                    result << field_name.to_s.to_sym
                end
            end

            # targetごとの指定フィールド一覧から和集合を作成する。
            def collect_union_fields(target_field_contexts, field_group_name)
                result = []

                target_field_contexts.each do |target_field_context|
                    target_field_context[field_group_name].each do |field_name|
                        result << field_name
                    end
                end

                result.uniq
            end

            # 許容型の和集合から不許容型の和集合を除外する。
            # 未定義targetは許容し、同名フィールドの型が混在する場合は除外する。
            def collect_exclusive_union_fields(target_field_contexts, field_group_name, excluded_field_group_name)
                included_fields = collect_union_fields(
                    target_field_contexts,
                    field_group_name,
                )
                excluded_fields = collect_union_fields(
                    target_field_contexts,
                    excluded_field_group_name,
                )

                included_fields - excluded_fields
            end

            # targetごとの指定フィールド一覧から積集合を作成する。
            def collect_intersection_fields(target_field_contexts, field_group_name)
                return [] if target_field_contexts.empty?

                result = target_field_contexts[0][field_group_name].dup

                target_field_contexts.drop(1).each do |target_field_context|
                    result = result & target_field_context[field_group_name]
                end

                result
            end

            # 複数の検索オプションを同時に参照しなければ判断できない関係を検査する。
            def validate_option_relations!(options)
                validate_model_relations!(options[:model_relations])

                validate_mlt_index_target_options!(
                    options[:mlt_instance],
                    options[:mlt_index_target],
                )

                if options[:build_model_bool] == true
                    validate_model_bool_body!(options[:raw_body])
                end
            end

            # model_relationsのRelationが、keyに指定されたモデルから作られていることを確認する。
            def validate_model_relations!(model_relations)
                return if model_relations.nil?

                model_relations.each do |model, relation|
                    next if relation.klass == model

                    raise ArgumentError,
                        "model_relations のモデルと Relation の klass が一致していません: " \
                        "#{model.name} != #{relation.klass.name}"
                end
            end

            # More Like Thisの基準インスタンスから同じtargetを解決し、
            # 指定されたindex targetと同じElasticsearch indexを指すか確認する。
            def validate_mlt_index_target_options!(mlt_instance_options, mlt_index_target_options)
                return if mlt_instance_options.nil?
                return if mlt_index_target_options.nil?

                instance_index_target = mlt_instance_options.class.are_search_index_target(
                    mlt_index_target_options.target_name,
                )

                if instance_index_target.nil? ||
                        instance_index_target.are_search_es_index_name != mlt_index_target_options.are_search_es_index_name
                    raise ArgumentError,
                        "instance から取得した index_target と指定された index_target が一致していません"
                end
            end

            # build_model_boolで変更するquery.bool.filterの構造を確認する。
            def validate_model_bool_body!(raw_body)
                if raw_body.instance_of?(Hash) == false
                    raise ArgumentError,
                        ":build_model_bool を使用する場合は :raw_body を Hash で指定してください: " \
                        "#{raw_body.inspect}"
                end

                validate_raw_body_key_pair!(raw_body, :query, "raw_body")

                query_key = raw_body_key(raw_body, :query)
                if query_key.nil?
                    raise ArgumentError,
                        ":build_model_bool を使用する場合は :raw_body に query が必要です"
                end

                query_body = raw_body[query_key]
                if query_body.instance_of?(Hash) == false
                    raise ArgumentError,
                        ":build_model_bool を使用する場合は query を Hash で指定してください: " \
                        "#{query_body.inspect}"
                end

                validate_raw_body_key_pair!(query_body, :bool, "query")

                bool_key = raw_body_key(query_body, :bool)
                if bool_key.nil?
                    raise ArgumentError,
                        ":build_model_bool を使用する場合は query.bool が必要です"
                end

                bool_body = query_body[bool_key]
                if bool_body.instance_of?(Hash) == false
                    raise ArgumentError,
                        ":build_model_bool を使用する場合は query.bool を Hash で指定してください: " \
                        "#{bool_body.inspect}"
                end

                validate_raw_body_key_pair!(bool_body, :filter, "query.bool")

                filter_key = raw_body_key(bool_body, :filter)
                return if filter_key.nil?

                filter_value = bool_body[filter_key]
                return if filter_value.nil?
                return if filter_value.instance_of?(Hash)
                return if filter_value.instance_of?(Array)

                raise ArgumentError,
                    ":build_model_bool を使用する場合は query.bool.filter を " \
                    "Hash、Array、nil のいずれかで指定してください: #{filter_value.inspect}"
            end

            # SymbolとStringの同名keyが同時にある曖昧なraw_bodyを拒否する。
            def validate_raw_body_key_pair!(hash, key, path)
                string_key = key.to_s

                if hash.key?(key) && hash.key?(string_key)
                    raise ArgumentError,
                        ":raw_body #{path} に #{key.inspect} と #{string_key.inspect} を同時に指定できません"
                end
            end

            # raw_bodyからSymbolまたはStringの実在するkeyを返す。
            def raw_body_key(hash, key)
                return key if hash.key?(key)

                string_key = key.to_s
                return string_key if hash.key?(string_key)

                nil
            end
        end
    end
end
