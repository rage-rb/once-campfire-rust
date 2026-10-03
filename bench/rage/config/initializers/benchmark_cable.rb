# frozen_string_literal: true

Rails.application.config.after_initialize do
  # The benchmark client names the stock Turbo class. Replace its runtime while
  # retaining the real Turbo signing helpers and signature key.
  Turbo.send(:remove_const, :StreamsChannel)
  Turbo.const_set(:StreamsChannel, BenchmarkTurboStreamsChannel)
end
