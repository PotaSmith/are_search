# frozen_string_literal: true

module AreSearch
    class Railtie < Rails::Railtie
        generators do
            require "generators/are_search/install_generator"
        end
        rake_tasks do
            load File.expand_path("../tasks/are_search.rake", __dir__)
        end
    end
end
