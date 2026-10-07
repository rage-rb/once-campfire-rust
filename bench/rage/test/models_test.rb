require_relative "test_helper"
require "open3"

class SequelModelsTest < BenchmarkTest
  def test_database_and_models_boot_without_active_record
    refute Object.const_defined?(:ActiveRecord)
    assert_empty PREPARED_STATEMENTS_AT_BOOT
    [Account, User, Session, Room, Membership, Message, RichText, Boost, Push::Subscription].each do |model|
      assert_operator model, :<, Sequel::Model
    end
    assert_equal Fiber.current, Sequel.current
    assert_equal :immediate, CampfireBenchmark::DB.transaction_mode
    assert_equal "wal", CampfireBenchmark::DB.fetch("PRAGMA journal_mode").get(:journal_mode)
    assert_equal 1, CampfireBenchmark::DB.fetch("PRAGMA foreign_keys").get(:foreign_keys)
    assert_equal 15, CampfireBenchmark::DB[:schema_migrations].count
    assert_instance_of Rooms::Open, Room.find(@room.id)
  end

  def test_sqlite_timestamps_preserve_utc_and_microseconds_across_local_dst_changes
    previous_timezone = ENV["TZ"]
    ENV["TZ"] = "America/New_York"
    timestamps = {
      "2026-01-07 12:34:56.123456" => Time.utc(2026, 1, 7, 12, 34, 56, 123456),
      "2026-07-07 12:34:56.123456" => Time.utc(2026, 7, 7, 12, 34, 56, 123456),
      "2026-03-08 02:30:00.123456" => Time.utc(2026, 3, 8, 2, 30, 0, 123456),
      "2026-11-01 01:30:00.123456" => Time.utc(2026, 11, 1, 1, 30, 0, 123456),
      "2026-07-07 12:34:56.123456+02:00" => Time.utc(2026, 7, 7, 10, 34, 56, 123456)
    }
    timestamps.each do |stored, expected|
      CampfireBenchmark::DB[:users].where(id: @user.id).update(updated_at: stored)
      actual = @user.refresh.updated_at
      assert_instance_of Time, actual
      assert_equal expected, actual, stored
      assert actual.utc?, stored
      assert_equal 123456, actual.usec
    end
  ensure
    ENV["TZ"] = previous_timezone
  end

  def test_message_and_rich_text_rollback_without_fts_unreads_or_enqueue
    Current.user = @user
    previous_touch = @room.refresh.updated_at
    CampfireBenchmark::DB.transaction do
      message = @room.create_message(body: "rolled back")
      assert message.persisted?
      assert_equal 1, RichText.count
      assert_equal 0, CampfireBenchmark::DB[:message_search_index].count
      assert_empty Rage::Deferred.__backend.pending_tasks.to_a
      raise Sequel::Rollback
    end
    assert_equal 0, Message.count
    assert_equal 0, RichText.count
    assert_equal 0, CampfireBenchmark::DB[:message_search_index].count
    assert_empty Rage::Deferred.__backend.pending_tasks.to_a
    assert_equal previous_touch, @room.refresh.updated_at
  end

  def test_rich_text_failure_rolls_back_parent_and_room_touch
    Current.user = @user
    previous_touch = @room.refresh.updated_at
    message = Message.new(room: @room, body: "cannot save")
    message.body.stub(:save, ->(*) { raise "rich text failed" }) do
      assert_raises(RuntimeError) { message.save }
    end
    assert_equal 0, Message.count
    assert_equal 0, RichText.count
    assert_equal previous_touch, @room.refresh.updated_at
    assert_empty Rage::Deferred.__backend.pending_tasks.to_a
  end

  def test_edit_reload_and_destroy_keep_rich_text_fts_and_touches
    Current.user = @user
    message = @room.create_message(body: "running dog")
    rich_text_id = message.body.id
    assert_equal [message.id], Message.search("run").select_map(Sequel[:messages][:id])
    original_room_time = @room.refresh.updated_at
    travel_to(Time.current + 2.seconds) do
      Message.find(message.id).update(body: "<b>edited cat</b>")
      assert_equal "edited cat", message.refresh.plain_text_body
      assert_equal rich_text_id, message.body.id
      assert_equal [message.id], Message.search("edit").select_map(Sequel[:messages][:id])
      assert_empty Message.search("run").all
      assert_operator @room.refresh.updated_at, :>, original_room_time
      Boost.create(message: message, content: "❤️")
      assert_equal 1, message.boosts_dataset.count
      message.destroy
    end
    assert_equal 0, Message.count
    assert_equal 0, RichText.count
    assert_equal 0, Boost.count
    assert_equal 0, CampfireBenchmark::DB[:message_search_index].count
    assert_equal 1, Rage::Deferred.__backend.pending_tasks.to_a.length
  end

  def test_session_refresh_boundary_preserves_existing_token_and_password_digest
    assert_equal @user, User.active.authenticate_by(email_address: @user.email_address, password: "secret123456")
    assert_nil User.active.authenticate_by(email_address: @user.email_address, password: "")
    now = Time.current.change(usec: 0)
    session = nil
    travel_to(now) { session = @user.start_session(user_agent: "original", ip_address: "127.0.0.1") }
    token = session.token
    assert_equal 24, token.length
    travel_to(now + 1.hour) do
      session.resume(user_agent: "boundary", ip_address: "127.0.0.2")
      assert_equal "original", session.refresh.user_agent
    end
    travel_to(now + 1.hour + 1.second) do
      session.resume(user_agent: "new", ip_address: "127.0.0.3")
      assert_equal "new", session.refresh.user_agent
      assert_equal token, session.token
      assert_equal now + 1.hour + 1.second, session.last_active_at
    end

  end

  def test_membership_grants_default_involvement_and_direct_room_type_guard
    member = User.create(name: "Member", role: :member)
    assert @room.memberships_dataset.first(user_id: member.id)
    closed = Rooms::Closed.create_for({ name: "Closed", creator: @user }, users: [member])
    assert_equal "mentions", closed.memberships_dataset.first.involvement
    direct = Rooms::Direct.create_for({ creator: @user }, users: [@user, member])
    assert direct.memberships_dataset.all.all? { |membership| membership.involvement == "everything" }
    assert_raises(Sequel::ValidationFailed) { direct.update(type: "Rooms::Open") }
    assert_equal "Rooms::Direct", direct.refresh.type
    closed.update(type: "Rooms::Open")
    assert_instance_of Rooms::Open, Room.find(closed.id)
    assert_equal 2, closed.memberships_dataset.count
  end

  def test_unread_updates_exclude_creator_connected_and_invisible_memberships
    Current.user = @user
    disconnected = User.create(name: "Disconnected")
    connected = User.create(name: "Connected")
    invisible = User.create(name: "Invisible")
    now = Time.current.change(usec: 0)
    @room.memberships_dataset.where(user_id: connected.id).update(connected_at: now - 60.seconds)
    @room.memberships_dataset.where(user_id: invisible.id).update(involvement: "invisible")
    travel_to(now) do
      message = @room.create_message(body: "unread")
      assert_equal message.created_at, @room.memberships_dataset.first(user_id: disconnected.id).unread_at
      [@user, connected, invisible].each do |user|
        assert_nil @room.memberships_dataset.first(user_id: user.id).unread_at
      end
    end
  end

  def test_push_queries_keep_involvement_mentions_and_presence_guards
    Current.user = @user
    mentioned = User.create(name: "Mentioned")
    everything = User.create(name: "Everything")
    excluded = User.create(name: "Connected")
    @room.memberships_dataset.where(user_id: everything.id).update(involvement: "everything")
    @room.memberships_dataset.where(user_id: excluded.id).update(involvement: "everything", connected_at: Time.current)
    [@user, mentioned, everything, excluded].each do |user|
      Push::Subscription.create(user: user, endpoint: "https://fcm.googleapis.com/#{user.id}")
    end
    message = @room.create_message(body: %(<action-text-attachment sgid="#{mentioned.attachable_sgid}"></action-text-attachment>))
    assert_equal "@Mentioned", message.plain_text_body
    assert_equal [mentioned.id], message.mentionees.select_map(Sequel[:users][:id])
    assert_equal [mentioned], ActionText::Attachable.from_attachable_sgid([mentioned.attachable_sgid])
    batches = []
    pool = Object.new
    pool.define_singleton_method(:queue) { |_, subscriptions| batches << subscriptions.select_map(Sequel[:push_subscriptions][:user_id]) }
    original_pool = Rails.configuration.x.web_push_pool
    Rails.configuration.x.web_push_pool = pool
    Room::MessagePusher.new(room: @room, message: message).push
    assert_equal [[everything.id], [mentioned.id]], batches
    assert_nil ActionText::Attachable.from_node(Nokogiri::HTML.fragment('<action-text-attachment sgid="invalid"></action-text-attachment>').at_css('action-text-attachment')).try(:id)
  ensure
    Rails.configuration.x.web_push_pool = original_pool if original_pool
  end

  def test_formatted_text_and_mentions_match_the_actual_rails_models
    Current.user = @user
    text = %(<p><mark>formatted</mark> <a href="javascript:alert(1)">link</a></p><ol start="3"><li value="4" style="color: red">item</li></ol><table><tr><td>cell</td></tr></table><action-text-attachment sgid="#{@user.attachable_sgid}"></action-text-attachment>)
    message = @room.create_message(body: text)
    output, error, status = Open3.capture3(RbConfig.ruby, File.expand_path("reference_probe.rb", __dir__),
      CampfireBenchmark::DB.opts[:database], message.id.to_s)
    assert status.success?, error
    probe = JSON.parse(output)
    assert_equal probe.fetch("body"), message.body.body.to_html
    assert_equal probe.fetch("plain_text"), message.plain_text_body
    html = BenchmarkMessageRendering.append(message)
    assert_equal probe.fetch("html"), html
    refute_includes html, "javascript:"
  end
end
