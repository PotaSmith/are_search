# AreSearch (Active Record Elastic SEARCH)

[English](./README.md) | [日本語](./README.ja.md)

AreSearchは、RailsとElasticsearchの検索・同期・運用を実装しつつ、利用側が構成や処理へ直接介入できる余地を残した検索基盤です。

Elasticsearch を隠すための gem ではありません。
Rails モデルから Elasticsearch への index、reindex、非同期同期、基本的な検索ヘルパーを提供します。

複雑な検索は、Elasticsearch の Query DSL を理解したうえで `AreSearch::Searcher.search` の `raw_body` に直接書く方針です。

## 方針

AreSearch は、以下を目的にしています。

* Rails モデルと Elasticsearch index の対応を明示する
* reindex と alias 切り替えの失敗を検知できる形にする
* 動いている本番 index へ検索改善の reindex を直接かけない
* IndexTarget により、新旧 index を並行同期して切り替え可能にする
* DB 更新後の Elasticsearch 同期を `are_search_sync_requests` に残す
* 検索処理を gem に閉じ込めすぎない
* 面倒な同期部分は gem が面倒を見る
* 必要になれば fork / clone してアプリ側に合わせて変更できる形にする

多機能な検索フレームワークは目指していません。

AreSearch は、同期や index 操作の異常を gem 内部に隠しません。

sync request、index marker、rake タスク、アラートメールを通じて、利用者が確認できる状態として残します。
何が正常で、何が未処理・失敗・固着・index 操作中なのかを、アプリ運用者が判断できるようにします。


## PostgreSQL と同期要求の保証

AreSearch が対象とするデータベースは PostgreSQL です。

検索対象レコードの変更と `are_search_sync_requests` への同期要求の記録は、同じ PostgreSQL データベースの同一トランザクション内で行います。
そのため、検索対象モデルと `are_search_sync_requests` が同じデータベースに存在する限り、「検索対象レコードの変更だけが commit され、その変更を Elasticsearch へ反映するための sync request が存在しない」という状態は、Rails または PostgreSQL のトランザクション機能自体に不具合がない限り、ありえません。

`after_commit` での直接同期、Job の登録、Elasticsearch への同期に失敗した場合でも、sync request は PostgreSQL に残ります。残った要求は rake タスクから再処理できます。


## 使っている index を reindex しない

AreSearch は、動いている本番 index に検索改善の reindex を直接かける設計を避けます。
tokenizer / analyzer / mappings を変える場合は、新しい IndexTarget を作り、旧 index と新 index を並行同期させます。
切り替えるのは alias ではなく、まずアプリ側の検索入口です。問題があれば、同期され続けている旧 index に戻せます。


## Installation

Gemfile に追加します。

```ruby
gem "are_search", git: "https://github.com/PotaSmith/are_search.git", tag: "v0.5.0"
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
rails db:migrate
```

生成される主なファイルは以下です。

```text
config/initializers/are_search.rb
db/migrate/xxxxxxxxxxxxxx_create_are_search_tables.rb
lib/tasks/are_search_retry_alert.rake
```

## Usage

モデルに `AreSearch::Searchable` を include します。

```ruby
class Article < ApplicationRecord
    include AreSearch::Searchable

    def self.are_search_es_mappings
        {
            default: {
                index_settings: {
                    max_result_window: 2_000,
                },
                properties: {
                    id:     { type: "long" },
                    title:  { type: "text", analyzer: "cjk_index_analyzer", search_analyzer: "cjk_search_analyzer" },
                    body:   { type: "text", analyzer: "cjk_index_analyzer", search_analyzer: "cjk_search_analyzer" },
                    status: { type: "keyword" },
                },
            },
        }
    end

    def are_search_es_data(target_name)
        case target_name
        when :default
            {
                id:     id,
                title:  title,
                body:   body,
                status: status,
            }
        else
            {}
        end
    end
end
```

初回 reindex の前に、index 操作を実行する環境では `config/initializers/are_search.rb` で `AreSearch.index_operation_enabled = true` を設定します。
そのうえで、index target を指定して初回 reindex を実行します。

```ruby
article_index = Article.are_search_index_target(:default)

article_index.are_search_es_reindex
```



検索します。

```ruby
article_index = Article.are_search_index_target(:default)

result = article_index.are_search_es_search(
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
docs/guide_setup.txt       セットアップ、初回導入
docs/guide_usage.txt       検索オプション、検索結果の扱い
docs/guide_operations.txt  reindex、同期、clean up、運用
docs/guide_reference.txt   設定、内部動作、IndexTarget、同期の仕組み
```

## Development

テストを実行します。

```bash
bundle exec rspec
```

## Contributing

この gem は、汎用検索フレームワークというより、Rails アプリで Elasticsearch を安全に扱うための実務寄りの雛形です。

利用するアプリに合わせて fork / clone して変更する使い方を想定しています。

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
