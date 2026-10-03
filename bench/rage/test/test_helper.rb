require "tmpdir"
require "fileutils"

# Every run owns its schema and WAL. Do not clean or transact around benchmark data:
# model after_commit hooks and fiber DB connections must execute for real.
TEST_STORAGE = Dir.mktmpdir("campfire-rage-test-")
ENV["RAILS_ENV"] = ENV["RAGE_ENV"] = "test"
ENV["SECRET_KEY_BASE"] = "a" * 128
ENV["CAMPFIRE_STORAGE_PATH"] = TEST_STORAGE
ENV["DATABASE_PATH"] = "#{TEST_STORAGE}/db.sqlite3"
require_relative "../config/environment"
require "minitest/autorun"
require "minitest/mock"
require "rack/mock"
require "active_support/testing/time_helpers"

ActiveRecord::Schema.verbose = false
load "#{CampfireBenchmark::REFERENCE}/db/schema.rb"

Minitest.after_run do
  ActiveRecord::Base.connection_pool.disconnect!
  FileUtils.remove_entry(TEST_STORAGE)
end

class ReferenceMessagesController < ActionController::Base
  helper :all
  include Rails.application.routes.url_helpers
  self.perform_caching = true
end

class BenchmarkTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  def run
    # Same synchronous fiber shim as rage/rspec; no reactor in unit tests.
    # Timers are suppressed, but Deferred writes use its real disk backend.
    @completed_current = []
    schedule = ->(&block) do
      fiber = Fiber.new(blocking: true) do
        Fiber.current.__set_id
        Fiber.current.__set_result(block.call)
        @completed_current << Current.attributes.dup
      end
      fiber.resume
      fiber
    end
    Fiber.stub(:schedule, schedule) do
      Fiber.stub(:await, ->(fibers) { Array(fibers).map(&:__get_result) }) do
        Iodine.stub(:run_after, ->(*) {}) do
          Iodine.stub(:run_every, ->(*) {}) { Iodine.stub(:publish, ->(*) {}) { super } }
        end
      end
    end
  end

  def setup
    Current.reset
    Rails.cache.clear
    db = ActiveRecord::Base.connection
    db.disable_referential_integrity do
      (db.tables - %w[schema_migrations ar_internal_metadata] - db.tables.grep(/message_search_index/)).each do |table|
        db.execute("DELETE FROM #{db.quote_table_name(table)}")
      end
      db.execute("DELETE FROM message_search_index")
    end
    Rage::Deferred.__backend.pending_tasks.each { |id, _| Rage::Deferred.__backend.remove_task(id) }
    Account.create!(name: FirstRun::ACCOUNT_NAME)
    @user = User.create!(id: 1, name: "David Hansson", email_address: "david@example.com", password: "secret123456", role: :administrator)
    Current.user = @user
    @room = Rooms::Open.create_for({ id: 1, name: FirstRun::FIRST_ROOM_NAME }, users: [@user])
    Current.reset
    @http = Rack::MockRequest.new(Rage.application)
    @broadcasts = []
  end

  def teardown
    Current.reset
    travel_back
  end

  def login(password: "secret123456")
    @http.post("/session", "IODINE_HAS_BODY" => true, params: { email_address: @user.email_address, password: password })
  end

  def cookie
    @cookie ||= Array(login.headers["set-cookie"]).first.split(";", 2).first
  end

  def env(cookie_value = cookie)
    Rack::MockRequest.env_for("http://example.org/cable", "HTTP_COOKIE" => cookie_value)
  end

  def capture_broadcasts
    Rage::Cable.stub(:broadcast, ->(name, data) { @broadcasts << [name, data] }) { yield }
  end

  # Drive the real Rage protocol/router without starting an Iodine reactor. Only
  # its socket transport is substituted; channels, callbacks and DB writes run.
  class Socket
    attr_reader :env, :writes, :streams
    attr_accessor :closed
    def initialize(env)
      @env, @writes, @streams = env, [], []
    end
    def write(data) = @writes << data
    def subscribe(name) = @streams << name
    def unsubscribe(name) = @streams.delete(name)
    def close = self.closed = true
  end

  def socket(cookie_value = cookie)
    socket = Socket.new(env(cookie_value))
    Rage.cable.__protocol.on_open(socket)
    socket
  end

  def subscribe(socket, params)
    identifier = params.to_json
    Rage.cable.__protocol.on_message(socket, { command: "subscribe", identifier: identifier }.to_json)
    [identifier, JSON.parse(socket.writes.last)]
  end

  def stream_params(channel, *streams)
    { channel: channel, signed_stream_name: Turbo::StreamsChannel.signed_stream_name(streams) }
  end
end
