# frozen_string_literal: true

module AreSearch
    module IndexDefinition
        extend self

        # AreSearch が作成する Elasticsearch index の静的な規則を定義する。
        # index の操作や状態管理は IndexManager が担当する。

        # alias の各要素と、alias と物理 index timestamp の境界に使用する。
        ES_INDEX_NAME_DELIMITER = "__"

        # Elasticsearch index 名を構成する各要素の共通形式。
        # 小文字英字で始まり、小文字英字とアンダーバーだけを使用する。
        ES_INDEX_NAME_ELEMENT_PATTERN = /\A[a-z][a-z_]*\z/.freeze

        # 空の index_prefix を index 名の先頭要素として残すための代理値。
        EMPTY_ES_INDEX_PREFIX = "are_search_no_prefix"

        # AreSearch が生成する物理 index 名の timestamp suffix。
        PHYSICAL_INDEX_TIMESTAMP_SUFFIX = Regexp.new(
            "#{Regexp.escape(ES_INDEX_NAME_DELIMITER)}" \
                "\\d{4}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{6}\\z",
        ).freeze

        RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME = :are_search_es_ar_model_class_name
        RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME = :are_search_es_ar_instance_key
        RESERVED_ES_FIELD_NAME_SETTING = { type: 'keyword' }

        RESERVED_ES_FIELD_NAMES = [
            RESERVED_ES_AR_MODEL_CLASS_NAME_FIELD_NAME,
            RESERVED_ES_AR_INSTANCE_KEY_FIELD_NAME,
        ].freeze

        # 値が Elasticsearch index 名の要素として使用できる形式かを判定する。
        def valid_es_index_name_element?(value)
            return false unless value.instance_of?(String)

            value.match?(ES_INDEX_NAME_ELEMENT_PATTERN)
        end

        # AreSearch の物理 index 名から alias 名を復元する。
        # timestamp 形式の物理 index 名でなければ nil を返す。
        def es_alias_name_from_index_name(index_name)
            index_name_string = index_name.to_s
            return nil unless index_name_string.match?(PHYSICAL_INDEX_TIMESTAMP_SUFFIX)

            index_name_string.sub(PHYSICAL_INDEX_TIMESTAMP_SUFFIX, "")
        end
    end
end
