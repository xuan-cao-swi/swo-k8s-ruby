require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # Log to STDOUT so the swo-k8s-collector picks the logs up from the container.
  # solarwinds_apm appends trace_id/span_id via ::Logger::Formatter, so use it
  # instead of Rails' SimpleFormatter (which bypasses it).
  config.log_tags = [:request_id]
  config.log_formatter = ::Logger::Formatter.new
  config.logger = ActiveSupport::TaggedLogging.new(
    ActiveSupport::Logger.new($stdout).tap { |logger| logger.formatter = config.log_formatter }
  )
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Keep the kube probe out of the logs.
  config.silence_healthcheck_path = "/health"

  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
end
