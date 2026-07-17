# AreSearch (Active Record Elastic SEARCH)

[English](./README.md) | [日本語](./README.ja.md)

AreSearch is a small search and synchronization template for using Elasticsearch in Rails applications.

It is not a gem for hiding Elasticsearch.
It provides Rails models with indexing, reindexing, asynchronous synchronization, and basic search helpers for Elasticsearch.

For complex searches, the intended approach is to write Elasticsearch Query DSL directly in the `raw_body` option of `AreSearch::Searcher.search` after understanding the DSL.

## Policy

AreSearch is designed for the following purposes.

* Make the relationship between Rails models and Elasticsearch indexes explicit
* Make reindexing and alias switch failures detectable
* Avoid reindexing a production index that is currently being used
* Use IndexTarget to keep old and new indexes synchronized in parallel and switch between them
* Leave Elasticsearch synchronization after DB updates in `are_search_sync_requests`
* Avoid locking search logic too deeply inside the gem
* Let the gem handle the tedious synchronization parts
* Keep the code easy to fork or clone and adapt to each application when needed

AreSearch does not aim to be a feature-rich search framework.

AreSearch does not hide synchronization or index operation problems inside the gem.

Through sync requests, index markers, rake tasks, and alert emails, it leaves visible state that users can inspect.
It is designed so that application operators can determine what is normal, what is pending, what failed, what is stuck, and what is currently under index operation.


## PostgreSQL and synchronization guarantees

AreSearch targets PostgreSQL as its Active Record database.

Changes to searchable records and the corresponding synchronization requests in `are_search_sync_requests` are written in the same transaction on the same PostgreSQL database.
As long as the searchable models and `are_search_sync_requests` use the same database, a state where a record change is committed without a sync request for reflecting that change in Elasticsearch cannot occur unless the transaction mechanism in Rails or PostgreSQL itself is faulty.

Even if direct synchronization from `after_commit`, job enqueueing, or Elasticsearch synchronization fails, the sync request remains in PostgreSQL and can be processed later by the rake task.


## Do not reindex an index that is being used

AreSearch avoids directly reindexing a running production index for search improvements.
When changing tokenizers, analyzers, or mappings, create a new IndexTarget and synchronize the old and new indexes in parallel.
The first switch should be the application-side search entry point, not the alias. If there is a problem, you can return to the old index, which is still being synchronized.


## Installation

Add this to your Gemfile.

```ruby
gem "are_search", git: "https://github.com/PotaSmith/are_search.git", tag: "v0.4.0"
```

To use the latest development version directly, specify `branch: "main"`.

```ruby
gem "are_search", git: "https://github.com/PotaSmith/are_search.git", branch: "main"
```

Or, for local development, use a local path.

```ruby
gem "are_search", path: "/path/to/are_search"
```

Then run bundle install as usual.

```bash
bundle install
```

Run the installer.

```bash
rails generate are_search:install
rails db:migrate
```

The main generated files are as follows.

```text
config/initializers/are_search.rb
db/migrate/xxxxxxxxxxxxxx_create_are_search_tables.rb
lib/tasks/are_search_retry_alert.rake
```

## Usage

Include `AreSearch::Searchable` in your model.

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

Before the initial reindex, set `AreSearch.index_operation_enabled = true` in `config/initializers/are_search.rb` for the environment that performs index operations.
Then specify the index target and run the initial reindex.

```ruby
article_index = Article.are_search_index_target(:default)

article_index.are_search_es_reindex
```



Run a search.

```ruby
article_index = Article.are_search_index_target(:default)

result = article_index.are_search_es_search(
    "search query",
    fields: [:title, :body],
)

result.records.each do |article|
    puts article.title
end
```

For complex searches, pass an Elasticsearch body directly with `raw_body`.

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

## Guides (Japanese)

See the following files for detailed usage.

```text
docs/guide_setup.txt       Setup and initial configuration
docs/guide_usage.txt       Search options and search result handling
docs/guide_operations.txt  Reindexing, synchronization, cleanup, and operations
docs/guide_reference.txt   Settings, internal behavior, IndexTarget, and synchronization mechanism
```

## Development

Run the tests.

```bash
bundle exec rspec
```

## Contributing

This gem is more of a practical template for safely using Elasticsearch in Rails applications than a general-purpose search framework.

It is intended to be forked or cloned and adapted to each application.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
