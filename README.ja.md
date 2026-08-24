# AreSearch (Active Record Elastic SEARCH)

[English](./README.md) | [日本語](./README.ja.md)

AreSearch は、Rails でデータベースと Elasticsearch との整合性を最重要に考えた gem です。

一般的な Elasticsearch 用の gem は、整合性を保証する設計にはなっていません。
管轄外だと無視している gem や、頑張っても穴が塞ぎきれていない gem しか見当たらないため、開発されたのが AreSearch です。

また、AreSearch は、Elasticsearch を隠すための gem ではありません。

AreSearch は、gem 独自の検索方法を覚えることに価値があるとは考えていません。
Elasticsearch を使うなら、gem 固有の記法よりも Elasticsearch 自体を理解する方が長く役立ちます。
SQL を理解しないまま Active Record の使い方だけを覚える状態が危ういのと同じように、Elasticsearch を理解せず検索 gem の操作だけに依存する設計を AreSearch では避けます。

## 方針

AreSearch は、以下を目的にしています。

* Rails モデルと Elasticsearch index の対応を明示する
* 動いている本番 index への reindex を通常運用にしない
* IndexTarget により、新旧 index を並行同期して切り替え可能にする
* DB 更新後の Elasticsearch 同期を `are_search_sync_requests` に残す
* 検索処理を gem に閉じ込めすぎない
* 面倒な同期部分は gem が面倒を見る
* 運用上カスタマイズが必要になりそうな同期処理は rake としてサンプル生成する

多機能な検索フレームワークは目指していません。

AreSearch は、同期や index 操作の異常を gem 内部に隠しません。

sync request、sync lock、rake タスク、アラートメールを通じて、利用者が確認できる状態として残します。
何が正常で、何が未処理・失敗・固着・index 操作中なのかを、アプリ運用者が判断できるようにします。


## データベースと同期要求の保証

検索対象レコードの変更と `are_search_sync_requests` への同期要求の記録は、同じデータベースの同一トランザクション内で行います。
そのため、検索対象モデルと `are_search_sync_requests` が同じデータベースに存在する限り、「検索対象レコードの変更だけが commit され、その変更を Elasticsearch へ反映するための sync request が存在しない」という状態は、Rails または使用するデータベースのトランザクション機能自体に不具合がない限り、ありえません。

`after_commit` での直接同期、Job の登録、Elasticsearch への同期に失敗した場合でも、sync request はデータベースに残ります。残った要求は rake タスクから再処理できます。

AreSearch は、標準のDBとしてPostgreSQLを使用しますが、DB固有処理は設定で差し替え可能です。


## reindex を前提にしない

AreSearch は、動いている本番 index に定期的に reindex をかける設計を避けます。
reindex が 10分で終わるならいいですが、3日、一週間かかるような場合、reindex は現実的ではありません。
AreSearch では複数の index の同時稼働、境界設定による bulk 投入により reindex 無しでのデータ更新を可能にしています。


## Installation

Gemfile に追加します。

```ruby
gem "are_search", git: "https://github.com/PotaSmith/are_search.git", tag: "v0.9.0"
```

開発中の最新版を直接使う場合は `branch: "main"` を指定できます。

```ruby
gem "are_search", git: "https://github.com/PotaSmith/are_search.git", branch: "main"
```

または、ローカルで使う場合。

```ruby
gem "are_search", path: "/path/to/are_search"
```

その後、通常通り bundle install します。

```bash
bundle install
```

インストーラを実行します。

```bash
rails generate are_search:install
# 生成されている config/are_search_searchable.rb.sample を config/are_search_searchable.rb に変更
rails db:migrate
```

生成される主なファイルは以下です。

```text
config/initializers/are_search.rb
config/are_search_searchable.rb.sample
db/migrate/xxxxxxxxxxxxxx_create_are_search_tables.rb
```

## Usage

モデルに `AreSearch::Searchable` を include し、設定から参照するメソッドを定義します。

```ruby
class Article < ApplicationRecord
    include AreSearch::Searchable

    def self.default_properties
        {
            id:     { type: "long" },
            title:  { type: "text", analyzer: "cjk_index_analyzer", search_analyzer: "cjk_search_analyzer" },
            body:   { type: "text", analyzer: "cjk_index_analyzer", search_analyzer: "cjk_search_analyzer" },
            status: { type: "keyword" },
        }
    end

    def default_indexable?
        true
    end

    def default_search_data
        {
            id:     id,
            title:  title,
            body:   body,
            status: status,
        }
    end
end
```

`config/are_search_searchable.rb` で IndexTarget と sync stage を設定します。

```ruby
AreSearch.searchable_class_setting = {
    "Article" => {
        default: {
            settings: {
                max_result_window: 2_000,
            },
            mappings: {},
            properties_method: :default_properties,
            indexable_method: :default_indexable?,
            stages: {
                "default" => {
                    data_method: :default_search_data,
                    enqueue: true,
                    after_commit: true,
                },
            },
        },
    },
}
```

IndexTarget は同期先の Elasticsearch index を表し、sync stage は同じ IndexTarget へ投入する完成ドキュメントの生成経路を表します。

初回 reindex の前に、index 操作を実行する環境では `config/initializers/are_search.rb` で `AreSearch.index_operation_enabled = true` を設定します。
そのうえで、index target を指定して初回 reindex を実行します。

```ruby
article_index = Article.are_search_index_target(:default)

article_index.are_search_reindex(stage_position: :first)
```

検索します。

```ruby
article_index = Article.are_search_index_target(:default)

result = article_index.are_search_search(
    "検索ワード",
    fields: [:title, :body],
)

result.records.each do |article|
    puts article.title
end
```

複雑な検索は `raw_body` で Elasticsearch の body を直接渡します。

```ruby
body = {
    query: {
        bool: {
            must: [
                { match: { title: "Rails" } },
            ],
        },
    },
}

article_index = Article.are_search_index_target(:default)

result = AreSearch::Searcher.search(
    [article_index],
    raw_body: body,
)
```

## Guides

詳しい使い方は以下を参照してください。

```text
docs/guide_setup.txt                     セットアップ、初回導入
docs/guide_index_targets_and_stages.txt  IndexTarget、sync stage、同期対象
docs/guide_usage.txt                     検索オプション、検索結果の扱い
docs/guide_operations.txt                reindex、同期、clean up、sync lock、運用
docs/guide_bulk_import.txt               データ投入とBulkIndexer
docs/guide_webapp.txt                    WEBアプリでの使用例
docs/guide_reference.txt                 設定、内部動作、低レベルAPI
```

## Development

テストを実行します。

```bash
bundle exec rspec
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
