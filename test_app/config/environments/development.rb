require "active_support/core_ext/integer/time"

Rails.application.configure do
    config.enable_reloading = true
    config.eager_load = false

    config.active_support.deprecation = :log
    config.active_record.migration_error = :page_load
end
