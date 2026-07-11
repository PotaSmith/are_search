# frozen_string_literal: true

require_relative "lib/are_search/version"

Gem::Specification.new do |spec|
    spec.name = "are_search"
    spec.version = AreSearch::VERSION
    spec.authors = ["PotaSmith"]

    spec.summary = "A small Rails concern for explicit Elasticsearch indexing and search."
    spec.description = "AreSearch provides Rails model integration, reindexing, deferred sync requests, and simple Elasticsearch search helpers without hiding Query DSL."

    spec.homepage = "https://github.com/PotaSmith/are_search"
    spec.license = "MIT"
    spec.required_ruby_version = ">= 3.0.0"

    spec.metadata["homepage_uri"] = spec.homepage
    spec.metadata["source_code_uri"] = spec.homepage
    spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

    spec.files = Dir[
        "lib/**/*",
        "LICENSE.txt",
        "README.ja.md",
        "README.md",
        "CHANGELOG.md",
    ]
    spec.require_paths = ["lib"]

    spec.add_dependency "railties",      ">= 7.2"
    spec.add_dependency "activerecord",  ">= 7.2"
    spec.add_dependency "activejob",     ">= 7.2"
    spec.add_dependency "actionmailer",  ">= 7.2"
    spec.add_dependency "activesupport", ">= 7.2"

    spec.add_dependency "elasticsearch", "~> 9.0"
    spec.add_dependency "elastic-transport"
    spec.add_dependency "faraday"

    spec.add_dependency "progress_bar"
end
