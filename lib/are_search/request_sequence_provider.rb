# frozen_string_literal: true

module AreSearch
    # sync request の世代番号を発行するproviderの基底クラス。
    class RequestSequenceProvider
        # 並列実行で重複しない、単調増加する整数を返す。
        def self.next_value
            raise NotImplementedError,
                "#{name}.next_value を実装してください"
        end
    end
end
