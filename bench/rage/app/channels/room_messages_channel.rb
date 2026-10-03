# frozen_string_literal: true

# Reference: app/channels/room_messages_channel.rb. Derive authorization from the
# signed GlobalID, never from a second client-controlled room parameter.
class RoomMessagesChannel < ApplicationChannel
  extend Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def self.guarded_stream?(stream_name)
    stream_name.to_s.split(":", 2).second == "messages"
  end

  def self.subscribable_room(user, stream_name)
    gid_param, suffix = stream_name.to_s.split(":", 2)
    if suffix == "messages" && room = GlobalID::Locator.locate(gid_param, only: Room)
      user.rooms.find_by(id: room.id)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def subscribed
    stream_name = self.class.verified_stream_name(params[:signed_stream_name])
    if stream_name.present? && self.class.subscribable_room(current_user, stream_name)
      stream_from stream_name
    else
      reject
    end
  end
end
