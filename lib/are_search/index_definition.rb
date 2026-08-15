# frozen_string_literal: true

module AreSearch
    module IndexDefinition
        extend self

        # AreSearch が作成する Elasticsearch index の静的な規則を定義する。
        # 利用側が指定する名前と、生成後の index 名の形式を担当する。
        # index の操作や状態管理は IndexManager が担当する。

        # alias の各要素と、alias と物理 index timestamp の境界に使用する。
        INDEX_NAME_DELIMITER = "__"

        # AreSearch が生成する物理 index 名の timestamp suffix。
        PHYSICAL_INDEX_TIMESTAMP_SUFFIX = Regexp.new(
            "#{Regexp.escape(INDEX_NAME_DELIMITER)}" \
                "\\d{4}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{6}\\z",
        ).freeze

        RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME = :are_search_reserved_ar_model_class_name
        RESERVED_AR_INSTANCE_KEY_FIELD_NAME     = :are_search_reserved_ar_instance_key
        RESERVED_INDEX_FIELD_NAME_SETTING = { type: 'keyword' }

        RESERVED_INDEX_FIELD_NAMES = [
            RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME,
            RESERVED_AR_INSTANCE_KEY_FIELD_NAME,
        ].freeze

        # 利用側が定義する識別名の共通形式。
        # 小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切る。
        DEFINITION_NAME_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/.freeze

        # 名前検査エラーで使用する共通の形式説明。
        DEFINITION_NAME_FORMAT_DESCRIPTION =
            "小文字英字で始まり、小文字英数字の単語を単一のアンダーバーで区切ってください"

        private_constant :DEFINITION_NAME_PATTERN
        private_constant :DEFINITION_NAME_FORMAT_DESCRIPTION

        # 利用側定義名の形式を説明する共通文言を返す。
        def definition_name_format_description
            DEFINITION_NAME_FORMAT_DESCRIPTION
        end

        # Elasticsearch index 名の先頭要素に使用する index_prefix を検査する。
        def valid_index_prefix?(index_prefix)
            return false if index_prefix.instance_of?(String) == false

            valid_definition_name?(index_prefix)
        end

        # index_prefix が不正な場合は例外を送出する。
        def valid_index_prefix!(index_prefix)
            return if valid_index_prefix?(index_prefix)

            raise ArgumentError, "不正な index_prefix 名です"
        end

        # Elasticsearch index 名のモデル識別要素に使用するテーブル名を検査する。
        def valid_ar_table_name?(ar_table_name)
            return false if ar_table_name.instance_of?(String) == false

            valid_definition_name?(ar_table_name)
        end

        # ar_table_name が不正な場合は例外を送出する。
        def valid_ar_table_name!(ar_table_name)
            return if valid_ar_table_name?(ar_table_name)

            raise ArgumentError, "不正な ar_table_name 名です"
        end

        # Elasticsearch index 名の target 識別要素に使用する名前を検査する。
        def valid_index_target_name?(index_target_name)
            return false if index_target_name.instance_of?(Symbol) == false

            index_target_name_string = index_target_name.to_s

            valid_definition_name?(index_target_name_string)
        end

        # index_target_name が不正な場合は例外を送出する。
        def valid_index_target_name!(index_target_name)
            return if valid_index_target_name?(index_target_name)

            raise ArgumentError, "不正な index_target_name 名です"
        end

        # Elasticsearch mapping のフィールド名を検査する。
        def valid_index_field_name?(field_name)
            return false if field_name.instance_of?(Symbol) == false

            field_name_string = field_name.to_s

            valid_definition_name?(field_name_string)
        end

        # field_name が不正な場合は例外を送出する。
        def valid_index_field_name!(field_name)
            return if valid_index_field_name?(field_name)

            raise ArgumentError, "不正な field_name 名です"
        end

        # 同期処理の sync_stage_name を検査する。
        def valid_sync_stage_name?(sync_stage_name)
            return false if sync_stage_name.instance_of?(String) == false
            return false if SyncLock.index_target_lock_sync_stage_name?(sync_stage_name)

            valid_definition_name?(sync_stage_name)
        end

        # sync_stage_name が不正な場合は例外を送出する。
        def valid_sync_stage_name!(sync_stage_name)
            return if valid_sync_stage_name?(sync_stage_name)

            raise ArgumentError, "不正な sync_stage_name 名です"
        end

        # AreSearch が生成する Elasticsearch alias 名か確認する。
        # 3要素を index_prefix、ar_table_name、index_target_name として個別に検査する。
        def valid_index_alias_name?(index_alias_name)
            return false if index_alias_name.instance_of?(String) == false

            name_elements = index_alias_name.split(INDEX_NAME_DELIMITER, -1)
            return false if name_elements.length != 3

            index_prefix = name_elements[0]
            ar_table_name = name_elements[1]
            index_target_name = name_elements[2].to_sym

            return false if valid_definition_name?(index_prefix) == false
            return false if valid_ar_table_name?(ar_table_name) == false
            return false if valid_index_target_name?(index_target_name) == false

            true
        end

        # Elasticsearch alias 名が不正な場合は例外を送出する。
        def valid_index_alias_name!(index_alias_name)
            return if valid_index_alias_name?(index_alias_name)

            raise ArgumentError, "不正な Elasticsearch alias 名です"
        end

        # AreSearch の物理 index 名から alias 名を復元する。
        # timestamp 形式の物理 index 名でなければ nil を返す。
        def index_alias_name_from_physical_index_name(physical_index_name)
            physical_index_name_string = physical_index_name.to_s
            return nil unless physical_index_name_string.match?(PHYSICAL_INDEX_TIMESTAMP_SUFFIX)

            physical_index_name_string.sub(PHYSICAL_INDEX_TIMESTAMP_SUFFIX, "")
        end

        # AreSearch が生成する物理 index 名か確認する。
        # timestamp suffix を除いた部分を alias 名として検査する。
        def valid_physical_index_name?(physical_index_name)
            return false if physical_index_name.instance_of?(String) == false

            index_alias_name = index_alias_name_from_physical_index_name(physical_index_name)
            return false if index_alias_name.nil?
            return false if valid_index_alias_name?(index_alias_name) == false

            true
        end

        # 物理 index 名が不正な場合は例外を送出する。
        def valid_physical_index_name!(physical_index_name)
            return if valid_physical_index_name?(physical_index_name)

            raise ArgumentError, "不正な物理 index 名です"
        end

        private

        # 利用側定義名に共通する予約名、空文字列、名前形式を検査する。
        def valid_definition_name?(name)
            return false if reserved_definition_name?(name)
            return false if name.empty?
            return false if name.match?(DEFINITION_NAME_PATTERN) == false

            true
        end

        # AreSearch 内部で使用する名前と衝突するか確認する。
        def reserved_definition_name?(name)
            return true if name == RESERVED_AR_MODEL_CLASS_NAME_FIELD_NAME.to_s
            return true if name == RESERVED_AR_INSTANCE_KEY_FIELD_NAME.to_s

            false
        end
    end
end
