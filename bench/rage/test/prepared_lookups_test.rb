require_relative "test_helper"

class PreparedLookupsTest < BenchmarkTest
  class ConcurrentUserQuery < Queries::Base
    def self.fetch(id, dataset)
      fetch_first(:by_id, id: id) { dataset }
    end
  end

  class YieldingUserQuery < Queries::Base
    def self.fetch(id, &dataset)
      fetch_first(:by_id, id: id, &dataset)
    end
  end

  def test_statement_definition_is_lazy_and_prepared_once_under_concurrent_first_calls
    dataset = User.where(id: :$id)
    count = 0
    count_mutex = Mutex.new
    probe = Object.new
    probe.define_singleton_method(:prepare) do |type, name|
      count_mutex.synchronize { count += 1 }
      Thread.pass
      dataset.prepare(type, name)
    end
    assert_equal 0, count
    gate = Queue.new
    threads = Array.new(4) { Thread.new { gate.pop; ConcurrentUserQuery.fetch(@user.id, probe) } }
    4.times { gate << true }
    assert_equal [@user] * 4, threads.map(&:value)
    assert_equal 1, count
    assert_nil ConcurrentUserQuery.fetch(-1, probe)
    assert_equal 1, count
  ensure
    threads&.each(&:join)
  end

  def test_dataset_construction_can_yield_without_holding_the_preparation_mutex
    dataset = User.where(id: :$id)
    suspended = Fiber.new do
      YieldingUserQuery.fetch(@user.id) do
        Fiber.yield
        dataset
      end
    end
    suspended.resume
    assert_equal @user, YieldingUserQuery.fetch(@user.id) { dataset }
    assert_equal @user, suspended.resume
  end

  def test_lazy_primary_key_statement_refreshes_when_an_sti_subclass_loads_later
    CampfireBenchmark::DB.synchronize do |connection|
      assert_equal @room, Rooms::Open.find(@room.id)
      original = connection.prepared_statements.fetch(:queries_record_rooms_open).first
      assert Queries::Room.exists_for_user?(model: Rooms::Open, user_id: @user.id, room_id: @room.id)
      authorization = connection.prepared_statements.fetch(:queries_room_rooms_open).first
      require_relative "support/special_open_room"
      special = SpecialOpenRoom.create_for({ name: "Special", creator: @user }, users: [@user])
      assert_instance_of SpecialOpenRoom, Rooms::Open.find(special.id)
      assert Queries::Room.exists_for_user?(model: Rooms::Open, user_id: @user.id, room_id: special.id)
      assert authorization.closed?
      assert original.closed?
      assert_equal @room, Rooms::Open.find(@room.id)
    end
  end

  def test_room_lookup_rebinds_access_checks_and_reuses_statement_without_caching_rows
    closed = Rooms::Closed.create_for({ name: "Private", creator: @user }, users: [@user])
    outsider = User.create(name: "Outsider")
    db = CampfireBenchmark::DB
    db.synchronize do |connection|
      assert_instance_of Rooms::Open, @user.find_room(@room.id)
      statement = connection.prepared_statements.fetch(:queries_room_for_user).first
      assert_nil outsider.find_room(closed.id)
      assert_equal closed, @user.find_room(closed.id)
      Room.where(id: closed.id).update(name: "Renamed")
      assert_equal "Renamed", @user.find_room(closed.id).name
      assert_same statement, connection.prepared_statements.fetch(:queries_room_for_user).first
      assert_raises(Sequel::NoMatchingRow) { outsider.find_room!(closed.id) }
      assert_nil @user.find_room(-1)
    end
  end

  def test_native_statements_belong_to_connections_and_reopen_after_disconnect
    db = CampfireBenchmark::DB
    lookup = lambda do |connection|
      assert_equal @room, @user.find_room(@room.id)
      connection.prepared_statements.fetch(:queries_room_for_user).first
    end
    holder = Fiber.new do
      db.synchronize { |connection| Fiber.yield [connection, lookup.call(connection)] }
    end
    first_connection, first_statement = holder.resume
    second_connection, second_statement = Fiber.new do
      db.synchronize { |connection| [connection, lookup.call(connection)] }
    end.resume
    refute_same first_connection, second_connection
    refute_same first_statement, second_statement
    holder.resume
    db.disconnect
    assert first_statement.closed?
    assert second_statement.closed?
    db.synchronize do |connection|
      refute_same first_statement, lookup.call(connection)
      statement = lookup.call(connection)
      assert_same statement, lookup.call(connection)
    end
  ensure
    holder.resume if holder&.alive?
  end

  def test_primary_key_and_association_reads_preserve_sti_and_missing_record_behavior
    closed = Rooms::Closed.create_for({ name: "Closed", creator: @user }, users: [@user])
    assert_instance_of Rooms::Closed, Room.find(closed.id.to_s)
    assert_instance_of Rooms::Closed, Rooms::Closed.find(closed.id)
    assert_raises(Sequel::NoMatchingRow) { Rooms::Open.find(closed.id) }
    assert_raises(Sequel::NoMatchingRow) { Room.find(-1) }
    assert_equal [closed, @room], Room.find([closed.id, @room.id, closed.id])
    Current.user = @user
    message = closed.create_message(body: "prepared associations")
    reloaded = Message.find(message.id)
    assert_instance_of Rooms::Closed, reloaded.room
    assert_equal @user, reloaded.creator
    assert_equal "prepared associations", reloaded.plain_text_body
    session = @user.start_session(user_agent: "test", ip_address: "127.0.0.1")
    assert_equal @user, Session.find(session.id).user
  end

  def test_first_row_and_failed_decoding_release_snapshots_before_later_writes
    db = CampfireBenchmark::DB
    db.synchronize do
      assert_equal @room, @user.find_room(@room.id)
      Fiber.new do
        db.transaction { Room.where(id: @room.id).update(name: "Another connection") }
      end.resume
      db.transaction { Room.where(id: @room.id).update(name: "Original connection") }
      assert_equal "Original connection", @user.find_room(@room.id).name

      Room.where(id: @room.id).update(updated_at: "invalid timestamp")
      assert_raises(Sequel::InvalidValue) { @user.find_room(@room.id) }
      Fiber.new do
        db.transaction { Room.where(id: @room.id).update(updated_at: Time.current) }
      end.resume
      db.transaction { Room.where(id: @room.id).update(name: "After decoding error") }
      assert_equal "After decoding error", @user.find_room(@room.id).name
    end
  end

  def test_text_bindings_preserve_binary_http_strings_and_authentication_scopes
    email = @user.email_address.b
    assert_equal @user, User.active.authenticate_by(email_address: email, password: "secret123456")
    assert_equal Encoding::BINARY, email.encoding
    assert_nil User.active.authenticate_by(email_address: "' OR 1=1 --", password: "secret123456")
    assert_nil User.active.where(id: -1).authenticate_by(email_address: email, password: "secret123456")
    unaddressed = User.create(name: "No email", password: "secret123456")
    assert_equal unaddressed, User.active.authenticate_by(email_address: nil, password: "secret123456")
    @user.update(status: :deactivated)
    assert_nil User.active.authenticate_by(email_address: email, password: "secret123456")
    assert_equal @user, User.authenticate_by(email_address: @user.email_address, password: "secret123456")
  end
end
