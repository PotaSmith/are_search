# frozen_string_literal: true

module AreSearch
    class SearchBodyPolicy

        # Elasticsearchへ送信するbodyとfield名の検査契約。
        # 利用するpolicyはこのクラスを継承し、両メソッドを実装する。

        class << self

            def valid?(es_params)
                raise NotImplementedError, "#{name}.valid? を実装してください"
            end

            def invalid_key?(key_name)
                raise NotImplementedError, "#{name}.invalid_key? を実装してください"
            end
        end
    end
end
