# frozen_string_literal: true

module AreSearch
    class SearchParamValidator
        class << self

            # index targetとモデルから検査用contextを作成し、
            # SearchOptionValidatorで検索オプションを検査・正規化する。
            # 外部入力として許可した値が不正な場合は、valid_optionsをnilにして
            # エラーメッセージを返す。
            # 複数オプション間の関係だけは、このクラスで追加検査する。
            def validate(index_targets, models, **dirty_options)
                context = AreSearch::SearchOptionContext.build(
                    index_targets,
                    models,
                    dirty_options[:runtime_mappings],
                )

                begin
                    options = AreSearch::SearchOptionValidator.validate(
                        dirty_options,
                        AreSearch::SearchOptionValidator::OPTION_DEFINITIONS,
                        context,
                    )
                rescue AreSearch::InvalidSearchOption => error
                    return [nil, error.message]
                end

                model_relations = options[:model_relations]
                if model_relations.nil? == false
                    validate_model_relations!(model_relations)
                end

                mlt_options = options[:mlt]
                if mlt_options.nil? == false
                    validate_mlt_options!(mlt_options)
                end

                if options[:build_model_bool] == true
                    if options.key?(:raw_body) == false
                        raise ArgumentError,
                            ":build_model_bool を使用する場合は :raw_body が必要です"
                    end

                    validate_model_bool_body!(options[:raw_body])
                end

                [options, nil]
            end

            private

            # More Like Thisの基準ドキュメントとfieldsの関係を検査する。
            def validate_mlt_options!(mlt_options)
                validate_mlt_index_target_options!(
                    mlt_options[:instance],
                    mlt_options[:index_target],
                )
                validate_mlt_fields!(
                    mlt_options[:index_target],
                    mlt_options[:fields],
                )
            end

            # model_relationsのRelationが、keyに指定されたモデルから作られていることを確認する。
            def validate_model_relations!(model_relations)
                model_relations.each do |model, relation|
                    next if relation.klass == model

                    raise ArgumentError,
                        "model_relations のモデルと Relation の klass が一致していません: " \
                        "#{model.name} != #{relation.klass.name}"
                end
            end

            # More Like Thisの基準インスタンスから同じtargetを解決し、
            # 指定されたindex targetと同じElasticsearch indexを指すか確認する。
            def validate_mlt_index_target_options!(instance_options, index_target_options)
                instance_index_target = instance_options.class.are_search_index_target(
                    index_target_options.target_name,
                )

                if instance_index_target.nil? ||
                        instance_index_target.are_search_es_index_name != index_target_options.are_search_es_index_name
                    raise ArgumentError,
                        "instance から取得した index_target と指定された index_target が一致していません"
                end
            end

            # More Like Thisのfieldsを基準targetから取得可能な型に限定する。
            def validate_mlt_fields!(index_target_options, fields_options)
                valid_fields = build_mlt_valid_fields(index_target_options)

                fields_options.each do |field_name|
                    next if valid_fields.include?(field_name)

                    raise ArgumentError,
                        "mlt.fields は mlt.index_target の text または keyword 型フィールドを指定してください: " \
                        "#{field_name.inspect}"
                end
            end

            # MLTの基準targetにあるtextまたはkeyword型フィールドだけを作る。
            def build_mlt_valid_fields(index_target)
                valid_fields = []
                properties = index_target.are_search_es_mappings[:properties]

                properties.each do |field_name, field_options|
                    next if field_options.instance_of?(Hash) == false

                    field_type = field_options[:type].to_s
                    next if field_type != "text" && field_type != "keyword"

                    valid_fields << field_name
                end

                valid_fields
            end

            # build_model_boolで変更するquery.bool.filterの構造を確認する。
            def validate_model_bool_body!(raw_body)
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
