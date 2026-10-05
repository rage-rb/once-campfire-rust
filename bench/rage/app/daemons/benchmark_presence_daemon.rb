class BenchmarkPresenceDaemon < Rage::Daemon
  scope :worker

  def perform
    loop do
      sleep BenchmarkPresenceBatch::INTERVAL_MS / 1000.0
      BenchmarkPresenceBatch.flush
    end
  end

  def cleanup
    BenchmarkPresenceBatch.flush
  end
end
