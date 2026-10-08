# frozen_string_literal: true

require "bundler/setup"
require "active_support"
require "action_cable"
require "websocket/driver"
require "minitest/autorun"
require "minitest/mock"
require "open3"

ENV["BENCHMARK_CABLE_COMPRESSION"] = "1"
require_relative "../../../reference/config/initializers/benchmark_cable_compression"

class BenchmarkRailsCableCompressionTest < Minitest::Test
  ENVIRONMENT = {
    "REQUEST_METHOD" => "GET",
    "HTTP_HOST" => "example.com",
    "REQUEST_URI" => "/cable",
    "HTTP_CONNECTION" => "Upgrade",
    "HTTP_UPGRADE" => "websocket",
    "HTTP_SEC_WEBSOCKET_VERSION" => "13",
    "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
    "HTTP_SEC_WEBSOCKET_PROTOCOL" => "actioncable-v1-json",
    "HTTP_SEC_WEBSOCKET_EXTENSIONS" => "permessage-deflate; client_max_window_bits"
  }.freeze

  class Socket
    attr_reader :writes

    def initialize
      @writes = []
    end

    def env = ENVIRONMENT
    def url = "ws://example.com/cable"
    def write(bytes) = @writes << bytes
  end

  class WorkerPool
    def initialize
      @jobs = []
    end

    def async_invoke(handler, method, message, connection:)
      @jobs << -> { handler.public_send(method, message) }
    end

    def drain
      @jobs.each(&:call)
      @jobs.clear
    end
  end

  def setup
    @socket = Socket.new
    driver = WebSocket::Driver.rack(@socket, protocols: ["actioncable-v1-json"])
    driver.start
    @handshake = @socket.writes.shift

    # Use Action Cable's real encoder, ClientSocket and websocket-driver framing,
    # replacing only the network sink so frames can be inspected byte for byte.
    client = ActionCable::Connection::ClientSocket.allocate
    client.instance_variable_set(:@ready_state, ActionCable::Connection::ClientSocket::OPEN)
    client.instance_variable_set(:@driver, driver)
    @connection = ActionCable::Connection::Base.allocate
    @connection.instance_variable_set(:@coder, ActiveSupport::JSON)
    @connection.instance_variable_set(:@websocket, client)
    @connection.instance_variable_set(:@worker_pool, @pool = WorkerPool.new)
    @connection.instance_variable_set(:@logger, ActiveSupport::Logger.new(File::NULL))
  end

  def test_complete_envelope_round_trips_in_unnegotiated_text_frame
    envelope = {
      identifier: '{"channel":"RoomMessagesChannel","signed_stream_name":"room"}',
      message: '<turbo-stream action="append">' + "<div>fanout bmk1z café & 火 🔥</div>" * 100 + "</turbo-stream>"
    }
    json = ActiveSupport::JSON.encode(envelope)
    assert_includes json, "\\u003c"
    assert_includes json, "\\u0026"

    @connection.transmit(envelope)
    frame = @socket.writes.fetch(0)
    assert_equal 0x81, frame.getbyte(0), "FIN + text opcode, with RSV1 clear"
    refute_includes @handshake, "Sec-WebSocket-Extensions"
    payload = frame_payload(frame)
    assert_equal json, inflate(payload)
    assert_operator payload.bytesize, :<, json.bytesize
    assert_equal ActiveSupport::JSON.decode(json), ActiveSupport::JSON.decode(inflate(payload))

    # The identical envelope uses the same Zlib format as Rage's serializer.
    require_relative "../../rage/lib/benchmark_cable_compression"
    serializer = Class.new do
      def serialize(_params, data) = ActiveSupport::JSON.encode(data)
      prepend BenchmarkCableCompression
    end.new
    assert_equal serializer.serialize(nil, envelope).b, payload
  end

  def test_small_protocol_frames_stay_plain_json
    [
      { type: "welcome" },
      { type: "ping", message: 1_800_000_000 },
      { type: "confirm_subscription", identifier: '{"channel":"HeartbeatChannel"}' },
      { identifier: '{"channel":"UnreadRoomsChannel"}', message: { roomId: 1 } }
    ].each do |envelope|
      @connection.transmit(envelope)
      assert_equal ActiveSupport::JSON.encode(envelope), frame_payload(@socket.writes.last).force_encoding(Encoding::UTF_8)
    end
  end

  def test_threshold_counts_encoded_bytes_and_preserves_the_connection_coder
    coder = Class.new { def encode(_data) = nil }.new
    @connection.instance_variable_set(:@coder, coder)
    ["a" * 255, "a" * 256, "火" * 86].each do |json|
      coder.stub(:encode, json) do
        payload = @connection.send(:encode, {})
        assert_equal Encoding::UTF_8, payload.encoding
        assert_equal json, json.bytesize < 256 ? payload : inflate(payload)
      end
    end
  end

  def test_each_envelope_has_an_independent_deflate_stream
    3.times do |index|
      envelope = { identifier: "room-#{index}", message: "bmk#{index}z " * 100 }
      @connection.transmit(envelope)
      assert_equal ActiveSupport::JSON.encode(envelope), inflate(frame_payload(@socket.writes.last))
    end
  end

  def test_incoming_json_decoder_is_unchanged
    command = { "command" => "subscribe", "identifier" => '{"channel":"HeartbeatChannel"}' }
    assert_equal command, @connection.send(:decode, ActiveSupport::JSON.encode(command))
  end

  def test_compression_happens_once_per_identifier_before_worker_callbacks
    map = ActionCable::SubscriptionAdapter::SubscriberMap.new
    first = '{"channel":"RoomMessagesChannel","signed_stream_name":"room"}'
    second = '{"signed_stream_name":"room","channel":"RoomMessagesChannel"}'
    20.times { add_stream(map, first, connection: @connection.dup) }
    add_stream(map, second)
    data = "<div>fanout bmk1z café & 火</div>" * 100
    notifications = []
    subscriber = ActiveSupport::Notifications.subscribe("transmit.action_cable") do |*, payload|
      notifications << payload
    end

    deflate = Zlib::Deflate.method(:new)
    compressions = 0
    Zlib::Deflate.stub(:new, ->(*args) { compressions += 1; deflate.call(*args) }) do
      map.broadcast("room", ActiveSupport::JSON.encode(data))
      assert_equal 2, compressions
      assert_empty @socket.writes, "compression precedes delivery callbacks"
      @pool.drain
      assert_equal 2, compressions
      assert_equal 21, @socket.writes.size
      envelopes = @socket.writes.map { |frame| ActiveSupport::JSON.decode(inflate(frame_payload(frame))) }
      assert_equal [first] * 20 + [second], envelopes.map { |envelope| envelope.fetch("identifier") }
      assert envelopes.all? { |envelope| envelope.fetch("message") == data }
      assert_equal 21, notifications.size
      assert notifications.all? { |payload| payload[:data] == data && payload[:via] == "streamed from room" }

      # A second publication gets a new cache, even with identical contents.
      map.broadcast("room", ActiveSupport::JSON.encode(data))
      @pool.drain
      assert_equal 4, compressions
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_custom_callbacks_and_coders_keep_their_original_behavior
    map = ActionCable::SubscriptionAdapter::SubscriberMap.new
    raw = []
    decoded = []
    add_stream(map, "raw", handler: -> message { raw << message })
    add_stream(map, "decoded", coder: ActiveSupport::JSON, handler: -> message { decoded << message })
    coder = Class.new do
      def self.decode(json) = { wrapped: ActiveSupport::JSON.decode(json) }
    end
    add_stream(map, "custom", coder: coder)
    data = { "body" => "bmk1z " * 100 }
    json = ActiveSupport::JSON.encode(data)
    map.broadcast("room", json)
    @pool.drain
    assert_kind_of String, raw.fetch(0)
    assert_equal json, raw.fetch(0)
    assert_equal [data], decoded
    envelope = ActiveSupport::JSON.decode(inflate(frame_payload(@socket.writes.fetch(0))))
    assert_equal({ "identifier" => "custom", "message" => { "wrapped" => data } }, envelope)
  end

  def test_null_and_small_broadcasts_use_shared_plain_envelopes
    map = ActionCable::SubscriptionAdapter::SubscriberMap.new
    2.times { add_stream(map, "room") }
    [nil, { "roomId" => 1 }].each do |data|
      Zlib::Deflate.stub(:new, ->(*) { flunk "small envelope should stay plain" }) do
        map.broadcast("room", ActiveSupport::JSON.encode(data))
        @pool.drain
        expected = ActiveSupport::JSON.encode(identifier: "room", message: data)
        assert_equal expected, frame_payload(@socket.writes.last).force_encoding(Encoding::UTF_8)
      end
    end
  end

  def test_redis_listener_inherits_the_same_fanout_hook
    require "action_cable/subscription_adapter/redis"
    assert_includes ActionCable::SubscriptionAdapter::Redis::Listener.ancestors, BenchmarkRailsCableCompression::SubscriberMap
  end

  def test_malformed_json_still_fails_in_the_worker_callback
    map = ActionCable::SubscriptionAdapter::SubscriberMap.new
    add_stream(map, "room")
    map.broadcast("room", "invalid JSON")
    assert_raises(JSON::ParserError) { @pool.drain }
  end

  def test_opt_in_and_load_hook_work_before_or_after_action_cable_loads
    initializer = File.expand_path("../../../reference/config/initializers/benchmark_cable_compression.rb", __dir__)
    [nil, "0", "1"].product([false, true]).each do |enabled, already_loaded|
      script = <<~RUBY
        require "active_support"
        require "action_cable"
        if #{already_loaded}
          ActionCable::Connection::Base
          ActionCable::Channel::Base
          require "action_cable/subscription_adapter/subscriber_map"
        end
        require #{initializer.inspect}
        hooked = ActionCable::Connection::Base.ancestors.include?(BenchmarkRailsCableCompression::Connection)
        abort "unexpected compression hook" unless hooked == #{enabled == "1"}
        hooked = ActionCable::Channel::Base.ancestors.include?(BenchmarkRailsCableCompression::Streams)
        abort "unexpected stream hook" unless hooked == #{enabled == "1"}
        require "action_cable/subscription_adapter/subscriber_map"
        hooked = ActionCable::SubscriptionAdapter::SubscriberMap.ancestors.include?(BenchmarkRailsCableCompression::SubscriberMap)
        abort "unexpected fanout hook" unless hooked == #{enabled == "1"}
      RUBY
      output, status = Open3.capture2e({ "BENCHMARK_CABLE_COMPRESSION" => enabled }, RbConfig.ruby, "-rbundler/setup", "-e", script)
      assert status.success?, output
    end
  end

  private

  def add_stream(map, identifier, coder: nil, handler: nil, connection: @connection)
    channel = ActionCable::Channel::Base.allocate
    channel.instance_variable_set(:@connection, connection)
    channel.instance_variable_set(:@identifier, identifier)
    callback = channel.send(:worker_pool_stream_handler, "room", handler, coder: coder)
    map.add_subscriber("room", callback, nil)
    callback
  end

  def frame_payload(frame)
    refute frame.getbyte(1) & 0x80 != 0, "server frames must be unmasked"
    length = frame.getbyte(1) & 0x7f
    case length
    when 126
      length = frame.byteslice(2, 2).unpack1("n")
      offset = 4
    when 127
      length = frame.byteslice(2, 8).unpack1("Q>")
      offset = 10
    else
      offset = 2
    end
    assert_equal offset + length, frame.bytesize
    frame.byteslice(offset, length).b
  end

  def inflate(payload)
    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
    inflater.inflate(payload.b + "\x00\x00\xff\xff".b).force_encoding(Encoding::UTF_8)
  ensure
    inflater&.close
  end
end
