# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.logger = ActiveSupport::Logger.new($stderr)
  config.log_level = :warn
end
