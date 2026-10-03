# frozen_string_literal: true

module BenchmarkMessageRendering
  def self.renderer
    request = Current.request
    BenchmarkRendererController.renderer.new(
      http_host: request&.host_with_port || ENV.fetch("BENCHMARK_HOST", "localhost:4555"),
      https: request&.ssl? || false
    )
  end

  def self.append(message)
    renderer.render(formats: [:turbo_stream], inline: '<%= turbo_stream.append dom_id(message.room, :messages), message %>', locals: { message: message })
  end

  def self.response(message)
    renderer.render(template: "messages/create", formats: [:turbo_stream], assigns: { message: message })
  end

  module Broadcasts
    def broadcast_create
      # Full reference partial, followed by reference's per-member unread lookup.
      Rage::Cable.broadcast("#{room.to_gid_param}:messages", BenchmarkMessageRendering.append(self))
      room.memberships.pluck(:user_id).each do |user_id|
        UnreadRoomsChannel.broadcast_to(user_id, { roomId: room.id })
      end
    end
  end

  module PushScheduling
    private
      def push_later(message)
        BenchmarkPushMessage.enqueue(room_id: id, message_id: message.id)
      end
  end
end
