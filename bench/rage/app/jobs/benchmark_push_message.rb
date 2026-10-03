# frozen_string_literal: true

class BenchmarkPushMessage
  include Rage::Deferred::Task

  def perform(room_id:, message_id:)
    room = Room.find(room_id)
    message = Message.find(message_id)
    # Preserve the reference pusher's payload construction and both empty subscription
    # queries. Real push delivery is outside this benchmark's one-user dataset.
    Room::MessagePusher.new(room: room, message: message).push
  end
end
