# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "warn")
  config.logger = ActiveSupport::Logger.new($stdout)
  config.active_support.report_deprecations = false
end
