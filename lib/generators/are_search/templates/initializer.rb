# frozen_string_literal: true

logger = ActiveSupport::Logger.new(ConfVars.get(:are_search, :log_file_path), 'daily')
logger.formatter = ::Logger::Formatter.new
logger.level = ConfVars.get(:are_search, :log_level)

AreSearch.logger = logger
# AreSearch.after_commit_mode = :job

# インデックス操作を行う環境のみtrueにする
AreSearch.index_operation_enabled = true

AreSearch.setup(
    index_prefix: "#{ConfVars.get(:are_search, :index_prefix)}_#{Rails.env}"
) do
    Elasticsearch::Client.new(
        url:      ConfVars.get(:are_search, :url),
        user:     ConfVars.get(:are_search, :user),
        password: ConfVars.get(:are_search, :password),
        adapter: :net_http,
        transport_options: {
            request: {
                open_timeout: 2,
                timeout:      10,
            },
            ssl: { verify: false },
        },
        ca_fingerprint: ConfVars.get(:are_search, :ca_fingerprint),
        log: Rails.env.development?,
        logger: logger,
    )
end
