require_relative "test_helper"

class PresenceBatchTest < BenchmarkTest
  def test_coalesces_events_for_multiple_memberships_into_one_update
    other_room = Rooms::Open.create_for({ name: "Other", creator: @user }, users: [@user])
    memberships = [@room.memberships.first, other_room.memberships.first]
    memberships.each { |membership| membership.update!(unread_at: Time.current) }
    queue = BenchmarkPresenceBatch.new
    memberships.each { |membership| 3.times { queue.enqueue(membership.id, :present) } }
    assert memberships.all? { |membership| membership.reload.connections == 0 }
    statements = []
    callback = ->(_, _, _, _, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { queue.flush }
    assert_equal 1, statements.count { |sql| sql.start_with?("SELECT") }
    assert_equal 1, statements.count { |sql| sql.start_with?("UPDATE") }
    assert statements.any? { |sql| sql.match?(/begin immediate/i) }
    memberships.each do |membership|
      assert_equal 3, membership.reload.connections
      assert membership.connected?
      assert_nil membership.unread_at
    end
    assert queue.idle?
  end

  def test_separate_worker_queues_use_latest_database_counts
    membership = @room.memberships.first
    workers = Array.new(2) { BenchmarkPresenceBatch.new }
    workers.each { |queue| queue.enqueue(membership.id, :present) }
    workers.each(&:flush)
    assert_equal 2, membership.reload.connections
    workers.first.enqueue(membership.id, :disconnected)
    workers.first.flush
    assert_equal 1, membership.reload.connections
    assert membership.connected?
    workers.last.enqueue(membership.id, :disconnected)
    workers.last.flush
    assert_equal 0, membership.reload.connections
    assert_nil membership.connected_at
  end

  def test_open_and_close_before_flush_does_not_leave_presence
    membership = @room.memberships.first
    queue = BenchmarkPresenceBatch.new
    queue.enqueue(membership.id, :present)
    queue.enqueue(membership.id, :disconnected)
    queue.flush
    assert_equal 0, membership.reload.connections
    assert_nil membership.connected_at
  end

  def test_expiry_refresh_and_unread_follow_reference_events
    membership = @room.memberships.first
    now = Time.current.change(usec: 0)
    membership.update!(connections: 10, connected_at: now - 61.seconds, unread_at: now)
    queue = BenchmarkPresenceBatch.new
    queue.enqueue(membership.id, :disconnected, at: now)
    queue.enqueue(membership.id, :refresh, at: now + 1.second)
    queue.flush
    assert_equal 1, membership.reload.connections
    assert_equal now + 1.second, membership.connected_at
    assert_equal now, membership.unread_at
    queue.enqueue(membership.id, :present, at: now + 2.seconds)
    queue.flush
    assert_equal 2, membership.reload.connections
    assert_nil membership.unread_at
  end

  def test_failed_flush_retries_without_losing_new_events
    membership = @room.memberships.first
    queue = BenchmarkPresenceBatch.new
    queue.enqueue(membership.id, :present)
    queue.stub(:write, ->(*) { queue.enqueue(membership.id, :present); raise "write failed" }) do
      assert_raises(RuntimeError) { queue.flush }
    end
    assert_equal 0, membership.reload.connections
    refute queue.idle?
    queue.flush
    assert_equal 2, membership.reload.connections
    assert queue.idle?
  end

  def test_later_worker_flush_does_not_move_activity_timestamp_backwards
    membership = @room.memberships.first
    now = Time.current.change(usec: 0)
    older, newer = Array.new(2) { BenchmarkPresenceBatch.new }
    older.enqueue(membership.id, :present, at: now)
    newer.enqueue(membership.id, :present, at: now + 1.second)
    newer.flush
    older.flush
    assert_equal 2, membership.reload.connections
    assert_equal now + 1.second, membership.connected_at
  end

  def test_replay_matches_reference_counts_ttl_unread_and_touches
    membership = @room.memberships.first
    now = Time.current.change(usec: 0)
    initial = { connections: 5, connected_at: now - 61.seconds, unread_at: now, updated_at: now - 65.seconds }
    actions = { present: :present, disconnected: :disconnected, refresh: :refresh_connection }
    [[:present, :present, :disconnected, :refresh, :disconnected],
      [:disconnected, :present, :refresh, :disconnected, :present],
      [:refresh, :disconnected, :present, :disconnected, :refresh]].each do |sequence|
      events = sequence.zip([0, 1, 62, 63, 64]).map { |action, seconds| [action, now + seconds.seconds] }
      membership.update_columns(initial)
      events.each { |action, at| travel_to(at) { membership.reload.public_send(actions.fetch(action)) } }
      expected = membership.reload.attributes.slice(*initial.keys.map(&:to_s))
      membership.update_columns(initial)
      queue = BenchmarkPresenceBatch.new
      events.each { |action, at| queue.enqueue(membership.id, action, at: at) }
      queue.flush
      assert_equal expected, membership.reload.attributes.slice(*initial.keys.map(&:to_s))
    end
  end

  def test_deleted_memberships_are_not_recreated_by_a_flush
    membership = @room.memberships.first
    queue = BenchmarkPresenceBatch.new
    queue.enqueue(membership.id, :present)
    membership.delete
    queue.flush
    assert_nil Membership.find_by(id: membership.id)
    assert queue.idle?
  end

  def test_server_startup_clears_previous_presence_before_workers_start
    membership = @room.memberships.first
    membership.present
    assert_equal 1, membership.reload.connections
    callback = nil
    Iodine.stub(:on_state, ->(state, &block) { callback = block if state == :pre_start }) do
      load File.expand_path("../config/initializers/benchmark_presence.rb", __dir__)
    end
    assert callback
    assert_equal 1, membership.reload.connections
    callback.call
    assert_equal 0, membership.reload.connections
    assert_nil membership.connected_at
  end
end
