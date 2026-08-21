# frozen_string_literal: true

module AreSearch
    class SearchParamValidator
        class << self

            # index targetとモデルから検査用contextを作成し、
            # SearchOptionValidatorで検索オプションを検査・正規化する。
            # 複数オプション間の関係だけは、このクラスで追加検査する。
            def validate!(index_targets, models, max_result_window, **dirty_options)
                context = AreSearch::SearchOptionContext.build(
                    index_targets,
                    models,
                    dirty_options[:runtime_mappings],
                )

                options = AreSearch::SearchOptionValidator.validate!(
                    dirty_options,
                    AreSearch::SearchOptionValidator::OPTION_DEFINITIONS,
                    context,
                )

                validate_paging_range!(options, max_result_window)

                model_relations = options[:model_relations]
                if model_relations.nil? == false
                    validate_model_relations!(model_relations)
                end

                mlt_options = options[:mlt]
                if mlt_options.nil? == false
                    MltLikeValidator.validate!(mlt_options[:like], mlt_options[:fields])
                end

                if options.key?(:build_model_bool)
                    if options.key?(:raw_body) == false
                        raise ArgumentError, ":build_model_bool を使用する場合は :raw_body が必要です"
                    end

                    if options[:build_model_bool] == true
                        validate_model_bool_body!(options[:raw_body])
                    end
                end

                options
            end

            private

            # page / per_page から算出した検索開始位置が、
            # Elasticsearch の取得可能範囲内にあることを確認する。
            def validate_paging_range!(options, max_result_window)
                page = AreSearch::SearcherUtils.resolve_page_default_option(options[:page], 1)
                per_page = AreSearch::SearcherUtils.resolve_page_default_option(options[:per_page], 25)
                from = (page - 1) * per_page

                return if from < max_result_window

                raise AreSearch::InvalidSearchOption, "opts[:page] と opts[:per_page] から算出した from が max_result_window 以上です"
            end

            # model_relationsのRelationが、keyに指定されたモデルから作られていることを確認する。
            def validate_model_relations!(model_relations)
                model_relations.each do |model, relation|
                    next if relation.klass == model

                    raise ArgumentError, "model_relations のモデルと Relation の klass が一致していません: #{model.name} != #{relation.klass.name}"
                end
            end

            # build_model_boolで変更するquery.bool.filterの構造を確認する。
            def validate_model_bool_body!(raw_body)
                validate_raw_body_key_pair!(raw_body, :query, "raw_body")

                query_key = raw_body_key(raw_body, :query)
                if query_key.nil?
                    raise ArgumentError, ":build_model_bool を使用する場合は :raw_body に query が必要です"
                end

                query_body = raw_body[query_key]
                if query_body.instance_of?(Hash) == false
                    raise ArgumentError, ":build_model_bool を使用する場合は query を Hash で指定してください: #{query_body.inspect}"
                end

                validate_raw_body_key_pair!(query_body, :bool, "query")

                bool_key = raw_body_key(query_body, :bool)
                if bool_key.nil?
                    raise ArgumentError, ":build_model_bool を使用する場合は query.bool が必要です"
                end

                bool_body = query_body[bool_key]
                if bool_body.instance_of?(Hash) == false
                    raise ArgumentError, ":build_model_bool を使用する場合は query.bool を Hash で指定してください: #{bool_body.inspect}"
                end

                validate_raw_body_key_pair!(bool_body, :filter, "query.bool")

                filter_key = raw_body_key(bool_body, :filter)
                return if filter_key.nil?

                filter_value = bool_body[filter_key]
                return if filter_value.nil?
                return if filter_value.instance_of?(Hash)
                return if filter_value.instance_of?(Array)

                raise ArgumentError, ":build_model_bool を使用する場合は query.bool.filter を Hash、Array、nil のいずれかで" \
                    "指定してください: #{filter_value.inspect}"
            end

            # SymbolとStringの同名keyが同時にある曖昧なraw_bodyを拒否する。
            def validate_raw_body_key_pair!(hash, key, path)
                string_key = key.to_s

                if hash.key?(key) && hash.key?(string_key)
                    raise ArgumentError, ":raw_body #{path} に #{key.inspect} と #{string_key.inspect} を同時に指定できません"
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

        class MltLikeValidator
            class << self

                # More Like Thisのlikeとfieldsの関係を検査する。
                def validate!(like_options, fields)
                    instance = like_options[:instance]
                    index_target = like_options[:index_target]

                    validate_index_target!(instance, index_target)
                    validate_fields!(index_target, fields)
                end

                private

                # 基準インスタンスから同じtargetを解決し、指定されたindex targetと同じElasticsearch indexを指すか確認する。
                def validate_index_target!(instance, index_target)
                    instance_index_target = instance.class.are_search_index_target(
                        index_target.index_target_name,
                    )

                    instance_index_alias_name = instance_index_target&.are_search_index_alias_name

                    if instance_index_alias_name != index_target.are_search_index_alias_name
                        raise ArgumentError, "mlt.like.instance から取得した index_target と mlt.like.index_target が一致していません"
                    end
                end

                # 基準targetのfieldsをMore Like Thisで使用可能な型と保存状態に限定する。
                def validate_fields!(index_target, fields)
                    mappings = index_target.are_search_index_mappings_for_index
                    properties = mappings[:properties]

                    fields.each do |field_name|
                        field_options = properties[field_name]

                        if mlt_field_type?(field_options) == false
                            raise ArgumentError, "mlt.fields は mlt.like.index_target の text または keyword 型フィールドを" \
                                "指定してください: #{field_name.inspect}"
                        end

                        next if source_field_available?(mappings[:_source], field_name)
                        next if field_options[:store] == true

                        raise ArgumentError, "mlt.fields は mlt.like.index_target の _source または store から取得可能な" \
                            "フィールドを指定してください: #{field_name.inspect}"
                    end
                end

                # fieldがMore Like Thisで使用可能なtextまたはkeyword型か確認する。
                def mlt_field_type?(field_options)
                    return false if field_options.instance_of?(Hash) == false

                    field_type = field_options[:type].to_s

                    field_type == "text" || field_type == "keyword"
                end

                # fieldが実際の_sourceに保存される設定か確認する。
                def source_field_available?(source_settings, field_name)
                    return false if source_settings.instance_of?(Hash) == false
                    return false if source_filter_match?(source_settings[:includes], field_name) == false
                    return false if source_filter_match?(source_settings[:excludes], field_name)

                    true
                end

                # _sourceのincludes / excludesがfieldに一致するか確認する。
                def source_filter_match?(filter_options, field_name)
                    filter_values = filter_options
                    unless filter_values.instance_of?(Array)
                        filter_values = [filter_values]
                    end

                    filter_values.each do |filter_value|
                        next if filter_value.nil?

                        return true if File.fnmatch?(filter_value.to_s, field_name.to_s)
                    end

                    false
                end
            end
        end
    end
end
