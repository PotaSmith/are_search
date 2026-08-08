Rails.application.configure do
    config.enable_reloading = false
    config.eager_load = false

    config.action_mailer.delivery_method = :test
    config.active_support.deprecation = :stderr
end
