# frozen_string_literal: true

module AreSearch
    class DatabaseSpecific

        # AreSearch が使用するDB固有処理の差し替え口。

        # 並列実行で重複しない、単調増加する同期要求の世代番号を返す。
        def self.next_request_sequence
            raise NotImplementedError,
                "#{name}.next_request_sequence を実装してください"
        end

        # 同期要求を登録または更新する。
        def self.upsert(
            ar_model_class_name:,
            index_target_name:,
            ar_instance_key:,
            es_index_name:,
            request_sequence:,
            request_sequence_at:
        )
            raise NotImplementedError,
                "#{name}.upsert を実装してください"
        end
    end
end
