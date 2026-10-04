require_relative "test_helper"

class HttpAuthenticationTest < BenchmarkTest
  def test_login_issues_real_rails_cookie_and_resolves_session_and_user
    assert_equal 200, @http.get("/up").status
    assert_includes @http.get("/session/new").body, 'name="password"'
    response = login
    assert_equal 302, response.status
    assert_equal "/", response.headers["location"]
    signed = Array(response.headers["set-cookie"]).first
    assert_includes signed, "httponly"
    assert_includes signed, "samesite=lax"
    authenticated = BenchmarkAuthentication.session_for(env(signed.split(";", 2).first))
    assert_equal @user, authenticated.user
    assert_equal authenticated.token, BenchmarkAuthentication.cookie_jar(env(signed.split(";", 2).first)).signed[:session_token]
    assert_equal "/rooms/#{@room.id}", @http.get("/", "HTTP_COOKIE" => cookie).headers["location"]
    assert_nil Current.user
    assert_nil Current.session
    assert_nil Current.request
  end

  def test_wrong_password_and_anonymous_or_tampered_cookie_are_rejected
    assert_equal 401, login(password: "incorrect").status
    ["", cookie.sub(/.$/, cookie.end_with?("a") ? "b" : "a")].each do |value|
      assert_nil BenchmarkAuthentication.session_for(env(value))
      response = @http.get("/rooms/#{@room.id}", "HTTP_COOKIE" => value)
      assert_equal 302, response.status
      assert_equal "/session/new", response.headers["location"]
      posted = @http.post("/rooms/#{@room.id}/messages", "HTTP_COOKIE" => value, "IODINE_HAS_BODY" => true,
        params: { message: { body: "unauthorized" } })
      assert_equal 302, posted.status
      assert_equal 0, Message.count
      rejected = socket(value)
      assert rejected.closed
      assert_equal({ "type" => "disconnect", "reason" => "unauthorized", "reconnect" => false }, JSON.parse(rejected.writes.last))
    end
    @user.update!(password: "secret&+=123456")
    assert_equal 302, login(password: "secret&+=123456").status
  end

  def test_scrape_returns_exactly_three_reference_signed_sources
    sources = ["/rooms/#{@room.id}", "/users/me/sidebar"].flat_map do |path|
      response = @http.get(path, "HTTP_COOKIE" => cookie)
      assert_equal 200, response.status
      Nokogiri::HTML.fragment(response.body).css("turbo-cable-stream-source").map do |node|
        [node["channel"], Turbo::StreamsChannel.verified_stream_name(node["signed-stream-name"])]
      end
    end
    assert_equal [["RoomMessagesChannel", "#{@room.to_gid_param}:messages"],
      ["Turbo::StreamsChannel", "rooms"], ["Turbo::StreamsChannel", "#{@user.to_gid_param}:rooms"]], sources
  end

  def test_membership_required_for_rooms_and_message_post
    hidden = Rooms::Closed.create_for({ name: "Hidden", creator: @user }, users: [])
    assert_equal 404, @http.get("/rooms/#{hidden.id}", "HTTP_COOKIE" => cookie).status
    before = Message.count
    response = @http.post("/rooms/#{hidden.id}/messages", "HTTP_COOKIE" => cookie,
      "IODINE_HAS_BODY" => true, params: { message: { body: "forbidden" } })
    assert_equal 404, response.status
    assert_equal before, Message.count
    assert_nil Current.user
  end
end

class CableSubscriptionsTest < BenchmarkTest
  def test_six_subscriptions_confirm_and_presence_writes_and_disconnects
    capture_broadcasts do
      connected = socket
      assert_equal({ "type" => "welcome" }, JSON.parse(connected.writes.first))
      params = [stream_params("RoomMessagesChannel", @room, :messages),
        stream_params("Turbo::StreamsChannel", :rooms), stream_params("Turbo::StreamsChannel", @user, :rooms),
        { channel: "UnreadRoomsChannel" }, { channel: "PresenceChannel", room_id: @room.id }, { channel: "HeartbeatChannel" }]
      params.each do |item|
        identifier, response = subscribe(connected, item)
        assert_equal({ "identifier" => identifier, "type" => "confirm_subscription" }, response)
      end
      assert_equal 6, connected.env["rage.cable"].size
      assert_equal 1, @room.memberships.first.reload.connections
      assert @room.memberships.first.connected?
      assert_includes @broadcasts, ["user_#{@user.id}_reads", { room_id: @room.id }]
      assert connected.streams.any? { |name| name.start_with?("cable:#{@room.to_gid_param}:messages:") }
      assert connected.streams.any? { |name| name.start_with?("cable:user_#{@user.id}_unreads:") }
      Rage.cable.__protocol.on_close(connected)
      membership = @room.memberships.first.reload
      assert_equal 0, membership.connections
      assert_nil membership.connected_at
      assert_nil Current.user
    end
  end

  def test_two_presence_connections_preserve_reference_connection_count
    capture_broadcasts do
      sockets = 2.times.map { socket }
      sockets.each { |connection| subscribe(connection, channel: "PresenceChannel", room_id: @room.id) }
      assert_equal 2, @room.memberships.first.reload.connections
      Rage.cable.__protocol.on_close(sockets.first)
      assert_equal 1, @room.memberships.first.reload.connections
      assert @room.memberships.first.connected?
      Rage.cable.__protocol.on_close(sockets.last)
      assert_equal 0, @room.memberships.first.reload.connections
    end
  end

  def test_room_membership_signed_room_and_generic_turbo_guards
    hidden = Rooms::Closed.create_for({ name: "Hidden", creator: @user }, users: [])
    connected = socket
    rejected = [stream_params("RoomMessagesChannel", hidden, :messages),
      stream_params("RoomMessagesChannel", @user, :messages),
      stream_params("RoomMessagesChannel", @room, :rooms),
      { channel: "RoomMessagesChannel", signed_stream_name: "tampered", room_id: @room.id },
      stream_params("Turbo::StreamsChannel", @room, :messages),
      { channel: "Turbo::StreamsChannel", signed_stream_name: "tampered" },
      { channel: "PresenceChannel", room_id: hidden.id }]
    capture_broadcasts do
      rejected.each do |params|
        identifier, response = subscribe(connected, params)
        assert_equal({ "identifier" => identifier, "type" => "reject_subscription" }, response)
      end
    end
    assert_empty connected.env["rage.cable"]
    assert_empty @broadcasts
    assert_equal 0, @room.memberships.first.reload.connections
    # The signed stream decides the room; a conflicting client room_id can't grant access.
    _, response = subscribe(connected, stream_params("RoomMessagesChannel", hidden, :messages).merge(room_id: @room.id))
    assert_equal "reject_subscription", response["type"]
    _, response = subscribe(connected, stream_params("RoomMessagesChannel", @room, :messages).merge(room_id: hidden.id))
    assert_equal "confirm_subscription", response["type"]
  end
end

class MessageWorkloadTest < BenchmarkTest
  def test_post_preserves_database_callbacks_two_broadcasts_and_full_turbo_response
    previous_touch = @room.updated_at
    response = nil
    travel_to(Time.current + 2.seconds) do
      capture_broadcasts do
        response = @http.post("/rooms/#{@room.id}/messages", "HTTP_COOKIE" => cookie,
          "IODINE_HAS_BODY" => true, params: { message: { body: "fanout bmk123z & <b>bold</b>", client_message_id: "client-1", creator_id: 999 }, authenticity_token: "" })
      end
    end
    assert_equal 200, response.status
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.headers["content-type"]
    message = Message.last
    assert_equal 1, Message.count
    assert_equal @user, message.creator
    assert_equal "client-1", message.client_message_id
    assert_equal 1, ActionText::RichText.where(record: message, name: "body").count
    assert_operator @room.reload.updated_at, :>, previous_touch
    assert_equal message.plain_text_body, ActiveRecord::Base.connection.select_value("SELECT body FROM message_search_index WHERE rowid = #{message.id}")
    assert_nil @room.memberships.first.unread_at
    assert_equal 2, @broadcasts.length
    assert_equal "#{@room.to_gid_param}:messages", @broadcasts.first.first
    assert_equal ["user_#{@user.id}_unreads", { roomId: @room.id }], @broadcasts.last
    assert_equal response.body, @broadcasts.first.last + "\n"
    fragment = Nokogiri::HTML.fragment(response.body)
    assert_equal "append", fragment.at_css("turbo-stream")["action"]
    assert_equal "messages_rooms_open_#{@room.id}", fragment.at_css("turbo-stream")["target"]
    assert_equal 8, fragment.css("form").length
    assert_equal 0, fragment.css('input[name="authenticity_token"]').length
    assert_includes fragment.text, "bmk123z & bold"
    assert_includes response.body, "message__actions-menu"
    assert_includes response.body, "reply_composer_outlet".tr("_", "-")
    assert_nil Current.user
    assert_nil Current.request
    queued = Rage::Deferred.__backend.pending_tasks.to_a
    assert_instance_of Rage::Deferred::Backends::Disk, Rage::Deferred.__backend
    assert_equal 1, queued.length
    _, context = queued.first
    assert_equal BenchmarkPushMessage, Rage::Deferred::Context.get_task(context)
    assert_equal({ room_id: @room.id, message_id: message.id }, Rage::Deferred::Context.get_kwargs(context))
    pushes = []
    original_pool = Rails.configuration.x.web_push_pool
    pool = Object.new
    pool.define_singleton_method(:queue) do |payload, subscriptions|
      original_pool.queue(payload, subscriptions)
      pushes << [payload, subscriptions.load.to_a]
    end
    Rails.configuration.x.web_push_pool = pool
    task = Fiber.schedule { BenchmarkPushMessage.new.__perform(context) }
    assert_equal true, Fiber.await([task]).first
    assert_equal 2, pushes.size
    assert pushes.all? { |_, subscriptions| subscriptions.empty? }
    assert_equal "David Hansson: #{message.plain_text_body}", pushes.first.first[:body]
    assert_nil Current.user
  ensure
    Rails.configuration.x.web_push_pool = original_pool if original_pool
  end

  def test_complete_reference_erb_and_actioncable_frame_match
    Current.user = @user
    message = @room.messages.create_with_attachment!(body: "fanout bmk321z & <b>bold</b>")
    rage = BenchmarkMessageRendering.append(message)
    # Independent Action View renderer, using the untouched reference partial and
    # the same no-CSRF setting as Rust. No marker-only or size-only assertions.
    Rails.cache.clear
    reference = ReferenceMessagesController.renderer.new(http_host: "localhost:4555", "rack.session" => {}).render(
      formats: [:turbo_stream], inline: '<%= turbo_stream.append dom_id(message.room, :messages), message %>', locals: { message: message })
    assert_equal reference, rage
    params = stream_params("RoomMessagesChannel", @room, :messages)
    expected = ActiveSupport::JSON.encode(identifier: params.to_json, message: reference)
    frame = Rage.cable.__protocol.serialize(params, rage)
    assert_equal expected, frame
    assert_equal params.to_json, JSON.parse(frame)["identifier"]
    assert_equal rage, JSON.parse(frame)["message"]
    assert_includes frame, '\\u003c'
    assert_includes frame, '\\u003e'
    assert_includes frame, '\\u0026'
    refute_includes frame, '"message":{"'
    assert_operator frame.bytesize, :>, 10_000

    # Production Rails renders eight masked tokens; Rust and this benchmark omit
    # them. Clear fragments so the comparison cannot reuse the no-token render.
    Rails.cache.clear
    ReferenceMessagesController.allow_forgery_protection = true
    csrf_reference = ReferenceMessagesController.renderer.new(http_host: "localhost:4555", "rack.session" => {}).render(
      formats: [:turbo_stream], inline: '<%= turbo_stream.append dom_id(message.room, :messages), message %>', locals: { message: message })
    assert_equal 8, Nokogiri::HTML.fragment(csrf_reference).css('input[name="authenticity_token"]').length
    normalized = csrf_reference.gsub(/<input[^>]*name="authenticity_token"[^>]*>/, "")
    assert_equal rage, normalized
    csrf_frame = ActiveSupport::JSON.encode(identifier: params.to_json, message: csrf_reference)
    puts "Payload check: no-CSRF HTML=#{rage.bytesize}, frame=#{frame.bytesize}; Rails CSRF HTML=#{csrf_reference.bytesize}, frame=#{csrf_frame.bytesize}"
  ensure
    ReferenceMessagesController.allow_forgery_protection = false
  end

  def test_current_is_isolated_by_request_and_task_fibers
    Current.user = @user
    other = Fiber.new { assert_nil Current.user; Current.user = "other"; Fiber.yield; assert_equal "other", Current.user }
    other.resume
    assert_equal @user, Current.user
    @http.get("/rooms/999999", "HTTP_COOKIE" => cookie)
    assert_equal @user, Current.user
    other.resume
    Fiber.schedule do
      assert_nil Current.user
      assert_nil Current.request
      assert_raises(ActiveRecord::RecordNotFound) { BenchmarkPushMessage.new.perform(room_id: -1, message_id: -1) }
    end
    assert_equal @user, Current.user
    assert_nil Current.request
    Fiber.schedule do
      assert_nil Current.user
      assert_nil Current.request
    end
  end
end

class DatasetValidationTest < BenchmarkTest
  def test_accepts_the_fill_dataset_without_changing_presence_or_messages
    membership = @room.memberships.first
    membership.present
    before = membership.reload.attributes
    assert BenchmarkDataset.validate!
    assert_equal before, membership.reload.attributes
    assert_equal 0, Message.count
  end

  def test_rejects_payload_changing_names_and_wrong_room_id
    @user.update!(name: "David")
    assert_includes assert_raises(ArgumentError) { BenchmarkDataset.validate! }.message, "fill.py administrator"
    @user.update!(name: "David Hansson")
    @room.update!(name: "Everyone")
    assert_includes assert_raises(ArgumentError) { BenchmarkDataset.validate! }.message, "All Talk room"
    @room.update!(name: FirstRun::FIRST_ROOM_NAME)
    @room.memberships.delete_all
    @room.update_columns(id: 2)
    assert_includes assert_raises(ArgumentError) { BenchmarkDataset.validate! }.message, "id 1"
  end

  def test_rejects_extra_users_and_push_subscriptions_before_jobs_can_retry
    bot = User.create!(name: "Bot", role: :bot)
    assert_includes assert_raises(ArgumentError) { BenchmarkDataset.validate! }.message, "one user"
    Membership.where(user: bot).delete_all
    bot.delete
    # Bypass endpoint DNS validation: no network delivery is supported by this slice.
    Push::Subscription.insert_all!([{ user_id: @user.id, endpoint: "https://fcm.googleapis.com/benchmark", created_at: Time.current, updated_at: Time.current }])
    assert_includes assert_raises(ArgumentError) { BenchmarkDataset.validate! }.message, "no push subscriptions"
  end
end
