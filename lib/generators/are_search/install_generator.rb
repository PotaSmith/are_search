# frozen_string_literal: true

module AreSearch
    module Generators
        class InstallGenerator < Rails::Generators::Base
            include Rails::Generators::Migration

            source_root File.expand_path("templates", __dir__)

            # rails generate are_search:install

            def copy_initializer
                template "initializer.rb", "config/initializers/are_search.rb"
            end

            # Searchableモデル構成用設定ファイルを生成する。
            def copy_searchable_class_setting
                template "searchable_class_setting.rb", "config/are_search_searchable.rb.sample"
            end

            def copy_migration
                migration_template "create_are_search_tables.rb", "db/migrate/create_are_search_tables.rb"
            end

            def self.next_migration_number(dirname)
                next_migration_number = current_migration_number(dirname) + 1
                ActiveRecord::Migration.next_migration_number(next_migration_number)
            end
        end
    end
end
