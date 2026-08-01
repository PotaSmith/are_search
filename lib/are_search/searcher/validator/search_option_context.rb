# frozen_string_literal: true

module AreSearch
    class SearchOptionContext

        FIELD_TYPE_TEXT    = :text
        FIELD_TYPE_KEYWORD = :keyword
        FIELD_TYPE_OTHER   = :other

        private_constant :FIELD_TYPE_TEXT
        private_constant :FIELD_TYPE_KEYWORD
        private_constant :FIELD_TYPE_OTHER

        attr_reader :models
        attr_reader :any_fields
        attr_reader :all_fields
        attr_reader :any_text_without_non_text_fields
        attr_reader :all_valid_text_fields
        attr_reader :any_text_or_keyword_without_other_type_fields
        attr_reader :all_valid_text_or_keyword_fields
        attr_reader :any_non_text_without_text_fields
        attr_reader :all_valid_non_text_fields

        # index target、モデル、runtime field定義から検索オプション検査用contextを作る。
        def self.build(index_targets, models, runtime_mappings)
            context = new(index_targets, models, runtime_mappings)

            context.build

            context
        end

        # context作成に必要な入力だけを保持する。
        def initialize(index_targets, models, runtime_mappings)
            @index_targets = index_targets
            @runtime_mappings = runtime_mappings
            @runtime_field_types = {}

            @models = models
            @any_fields = []
            @all_fields = []
            @any_text_without_non_text_fields = []
            @all_valid_text_fields = []
            @any_text_or_keyword_without_other_type_fields = []
            @all_valid_text_or_keyword_fields = []
            @any_non_text_without_text_fields = []
            @all_valid_non_text_fields = []
        end

        # 全フィールド名を対象に、target間の存在条件と型条件からcontextを作る。
        def build
            normalize_context_models

            build_runtime_field_types
            properties_list = build_properties_list

            # target間の判定対象になる全フィールド名を、従来の記述順を維持して作る。
            field_names = properties_list.map(&:keys).flatten.uniq

            field_names.each do |field_name|
                add_field_to_context!(
                    field_name,
                    properties_list,
                )
            end
        end

        private

        # モデル一覧がClassのArrayであることを確認して重複を除く。
        def normalize_context_models
            if @models.instance_of?(Array) == false
                raise ArgumentError,
                    "context.models は Array で指定してください: #{models.inspect}"
            end

            normalized_models = []

            @models.each do |model|
                if model.instance_of?(Class) == false
                    raise ArgumentError,
                        "context.models はモデルClassのArrayで指定してください: #{model.inspect}"
                end

                normalized_models << model
            end

            @models = normalized_models.uniq
        end

        # runtime_mappingsから、context作成に使えるフィールド名と3分類の型だけを作る。
        # 構造の正式な検査はSearchOptionValidatorが行うため、不完全な定義は使用しない。
        def build_runtime_field_types
            return if @runtime_mappings.instance_of?(Hash) == false

            @runtime_mappings.each do |field_name, field_options|
                next if field_options.instance_of?(Hash) == false
                next if field_name.instance_of?(Symbol) == false
                next if field_options.key?(:type) == false

                field_type = field_options[:type]

                if field_type.to_s == "text"
                    @runtime_field_types[field_name] = FIELD_TYPE_TEXT
                elsif field_type.to_s == "keyword"
                    @runtime_field_types[field_name] = FIELD_TYPE_KEYWORD
                else
                    @runtime_field_types[field_name] = FIELD_TYPE_OTHER
                end
            end

            @runtime_field_types
        end

        # 各targetのpropertiesを、targetの順序を維持したArrayで返す。
        def build_properties_list
            properties_list = []

            @index_targets.each do |index_target|
                mappings = index_target.are_search_es_mappings
                properties = mappings[:properties]
                properties = {} if properties.instance_of?(Hash) == false

                field_types = {}
                properties.each do |field_name, value|
                    next if value.instance_of?(Hash) == false
                    field_type = value[:type]

                    if field_type.to_s == "text"
                        field_types[field_name] = FIELD_TYPE_TEXT
                    elsif field_type.to_s == "keyword"
                        field_types[field_name] = FIELD_TYPE_KEYWORD
                    else
                        field_types[field_name] = FIELD_TYPE_OTHER
                    end
                end
                @runtime_field_types.each do |field_name, type|
                    field_types[field_name] = type
                end

                properties_list << field_types
            end

            properties_list
        end

        # target間の存在条件と型条件を直接確認し、該当するcontext集合へ追加する。
        def add_field_to_context!(field_name, properties_list)

            any_field = properties_list.any?{|field_types| field_types.key?(field_name) }

            all_field = properties_list.all?{|field_types| field_types.key?(field_name) }

            any_text = properties_list.any?{|field_types| field_types[field_name] == FIELD_TYPE_TEXT }

            any_keyword = properties_list.any?{|field_types| field_types[field_name] == FIELD_TYPE_KEYWORD }

            any_non_text = properties_list.any?{|field_types|
                field_types.key?(field_name) &&
                    field_types[field_name] != FIELD_TYPE_TEXT
            }

            any_other_type = properties_list.any?{|field_types|
                field_types.key?(field_name) &&
                    field_types[field_name] != FIELD_TYPE_TEXT &&
                    field_types[field_name] != FIELD_TYPE_KEYWORD
            }

            all_text = properties_list.all?{|field_types| field_types[field_name] == FIELD_TYPE_TEXT }

            all_text_or_keyword = properties_list.all?{|field_types|
                field_types[field_name] == FIELD_TYPE_TEXT ||
                field_types[field_name] == FIELD_TYPE_KEYWORD
            }

            all_non_text = properties_list.all?{|field_types|
                field_types.key?(field_name) &&
                    field_types[field_name] != FIELD_TYPE_TEXT
            }

            if any_field
                @any_fields << field_name
            end

            if all_field
                @all_fields << field_name
            end

            if any_text && any_non_text == false
                @any_text_without_non_text_fields << field_name
            end

            if all_text
                @all_valid_text_fields << field_name
            end

            if (any_text || any_keyword) && any_other_type == false
                @any_text_or_keyword_without_other_type_fields << field_name
            end

            if all_text_or_keyword
                @all_valid_text_or_keyword_fields << field_name
            end

            if any_non_text && any_text == false
                @any_non_text_without_text_fields << field_name
            end

            if all_non_text
                @all_valid_non_text_fields << field_name
            end
        end
    end
end
