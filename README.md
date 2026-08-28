# AreSearch (Active Record Elastic SEARCH)

[English](./README.md) | [日本語](./README.ja.md)

AreSearch is a gem for Rails that treats consistency between the database and Elasticsearch as its highest priority.

General-purpose Elasticsearch gems are not designed to guarantee consistency.
I could only find gems that either treat consistency as outside their scope or try to address it but still leave gaps. AreSearch was developed in response to this.

AreSearch is also not a gem for hiding Elasticsearch.

AreSearch does not consider learning gem-specific search methods to be valuable in itself.
When using Elasticsearch, understanding Elasticsearch itself is more useful in the long term than learning notation specific to a gem.
Just as relying only on Active Record without understanding SQL is risky, AreSearch avoids designs that depend only on search gem operations without understanding Elasticsearch.

## Policy

AreSearch is designed with the following goals.

* Make the relationship between Rails models and Elasticsearch indexes explicit
* Avoid making reindexing of a running production index part of normal operations
* Use IndexTarget to keep old and new indexes synchronized in parallel and allow switching between them
* Keep Elasticsearch synchronization requests after DB updates in `are_search_sync_requests`
* Avoid locking search processing too deeply inside the gem
* Let the gem handle the tedious synchronization work
* Provide rake task samples for synchronization processes that may require operational customization

AreSearch does not aim to be a feature-rich search framework.

AreSearch does not hide synchronization or index operation problems inside the gem.

Through sync requests, sync locks, rake tasks, and alert emails, it leaves state visible for users to inspect.
It is designed so that application operators can determine what is normal, what is pending, what failed, what is stuck, and what is currently under index operation.

## Database and synchronization request guarantees

Changes to searchable records and the corresponding synchronization requests in `are_search_sync_requests` are written within the same transaction on the same database.
As long as the searchable models and `are_search_sync_requests` exist in the same database, a state where only the searchable record change is committed without a sync request for reflecting that change in Elasticsearch cannot occur unless the transaction mechanism in Rails or the database itself is faulty.

Even if direct synchronization from `after_commit`, Job enqueueing, or Elasticsearch synchronization fails, the sync request remains in the database. Remaining requests can be processed later through rake tasks.

AreSearch uses PostgreSQL as its standard database, but database-specific processing can be replaced through configuration.

## Do not depend on reindexing

AreSearch avoids designs that periodically reindex a running production index.
If a reindex finishes in 10 minutes, that may be acceptable, but if it takes three days or a week, reindexing is no longer practical.
AreSearch allows index data to be updated without relying on reindexing by running multiple indexes in parallel and combining bulk indexing with boundary-based synchronization.

## Installation

Add this to your Gemfile.

```ruby
gem "are_search", git: "https://github.com/PotaSmith/are_search.git", tag: "v0.9.1"
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
# rename generated config/are_search_searchable.rb.sample to config/are_search_searchable.rb
rails db:migrate
```

The main generated files are:

```text
config/initializers/are_search.rb
config/are_search_searchable.rb.sample
db/migrate/xxxxxxxxxxxxxx_create_are_search_tables.rb
```

## Usage

Include `AreSearch::Searchable` in the model and define the methods referenced by the configuration.

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

Configure IndexTargets and sync stages in `config/are_search_searchable.rb`.

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

An IndexTarget represents the destination Elasticsearch index, while a sync stage represents a path for generating the complete document written to the same IndexTarget.

Before the initial reindex, set `AreSearch.index_operation_enabled = true` in `config/initializers/are_search.rb` for the environment that performs index operations.
Then specify the index target and run the initial reindex.

```ruby
article_index = Article.are_search_index_target(:default)

article_index.are_search_reindex(stage_position: :first)
```

Run a search.

```ruby
article_index = Article.are_search_index_target(:default)

result = article_index.are_search_search(
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
docs/guide_setup.txt                     Setup and initial configuration
docs/guide_index_targets_and_stages.txt  IndexTarget, sync stages, and synchronization targets
docs/guide_usage.txt                     Search options and search result handling
docs/guide_operations.txt                Reindexing, synchronization, cleanup, sync locks, and operations
docs/guide_bulk_import.txt               Data import and BulkIndexer operations
docs/guide_webapp.txt                    Example of using it in a web application
docs/guide_reference.txt                 Settings, internal behavior, and low-level APIs
```

## Development

Run the tests.

```bash
bundle exec rspec
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

