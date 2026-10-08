# frozen_string_literal: true

# Encoding/fan-out microbenchmark, not a network or server-capacity measurement.
mode = ARGV.fetch(0)
abort "usage: measure_compression.rb plain|per-client|shared" unless %w[plain per-client shared].include?(mode)
ENV["BENCHMARK_CABLE_COMPRESSION"] = mode == "shared" ? "1" : "0"
require "bundler/setup"
require "action_cable"
require "active_support/logger"
require_relative "../../reference/config/initializers/benchmark_cable_compression"
ActionCable::Connection::Base.prepend(BenchmarkRailsCableCompression::Connection) if mode == "per-client"
require "action_cable/subscription_adapter/subscriber_map"

class CompressionCounter
  attr_accessor :count
  def initialize = @count = 0
end
counter = CompressionCounter.new
counter_module = Module.new do
  define_method(:new) do |*args|
    counter.count += 1
    super(*args)
  end
end
Zlib::Deflate.singleton_class.prepend(counter_module)

class CompressionBenchmarkSink
  attr_accessor :bytes, :frames
  def initialize = reset
  def reset = (@bytes = @frames = 0)
  def transmit(payload)
    @bytes += payload.bytesize
    @frames += 1
  end
end

class CompressionBenchmarkPool
  def async_invoke(handler, method, message, connection:)
    handler.public_send(method, message)
  end
end

clients = Integer(ENV.fetch("CLIENTS", "1000"))
broadcasts = Integer(ENV.fetch("BROADCASTS", "20"))
identifier = '{"channel":"RoomMessagesChannel","signed_stream_name":"benchmark-room"}'
# Supply a captured Turbo HTML payload for application-specific measurements.
data = ENV["PAYLOAD"] ? File.read(ENV["PAYLOAD"]) : '<turbo-stream action="append">' + "<div>fanout bmk1z café & 火</div>" * 150 + "</turbo-stream>"
json = ActiveSupport::JSON.encode(data)
map = ActionCable::SubscriptionAdapter::SubscriberMap.new
sink = CompressionBenchmarkSink.new
pool = CompressionBenchmarkPool.new
logger = ActiveSupport::Logger.new(File::NULL)
clients.times do
  connection = ActionCable::Connection::Base.allocate
  connection.instance_variable_set(:@coder, ActiveSupport::JSON)
  connection.instance_variable_set(:@websocket, sink)
  connection.instance_variable_set(:@worker_pool, pool)
  connection.instance_variable_set(:@logger, logger)
  channel = ActionCable::Channel::Base.allocate
  channel.instance_variable_set(:@connection, connection)
  channel.instance_variable_set(:@identifier, identifier)
  callback = channel.send(:worker_pool_stream_handler, "room", nil)
  map.add_subscriber("room", callback, nil)
end

3.times { map.broadcast("room", json) }
sink.reset
counter.count = 0
GC.start
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
broadcasts.times { map.broadcast("room", json) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts JSON.pretty_generate(
  mode: mode, ruby: RUBY_DESCRIPTION,
  actioncable: Gem.loaded_specs.fetch("actioncable").version.to_s,
  clients: clients, broadcasts: broadcasts, elapsed_seconds: elapsed,
  deliveries: sink.frames, deliveries_per_second: sink.frames / elapsed,
  compressions: counter.count, payload_bytes_per_delivery: sink.bytes / sink.frames
)
