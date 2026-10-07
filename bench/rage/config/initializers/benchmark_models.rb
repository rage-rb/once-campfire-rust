# frozen_string_literal: true

Rails.application.config.after_initialize do
  Rails.configuration.x.web_push_pool = BenchmarkPushPool.new
end
