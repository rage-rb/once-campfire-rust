# frozen_string_literal: true

class BenchmarkPushPool
  def queue(payload, subscriptions)
    raise "Benchmark dataset must have no eligible push recipients" if subscriptions.all.any?
  end
end
