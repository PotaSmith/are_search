require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module TestApp
  class Application < Rails::Application
    config.load_defaults 8.1
  end
end
