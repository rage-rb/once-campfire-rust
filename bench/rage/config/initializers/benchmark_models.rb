# frozen_string_literal: true

Rails.application.config.after_initialize do
  Message.prepend BenchmarkMessageRendering::Broadcasts
  Room.prepend BenchmarkMessageRendering::PushScheduling
  Rails.configuration.x.web_push_pool = BenchmarkPushPool.new
end
