# frozen_string_literal: true

# Reference: app/channels/room_messages_channel.rb. Derive authorization from the
# signed GlobalID, never from a second client-controlled room parameter.
class RoomMessagesChannel < ApplicationChannel
  extend Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def self.guarded_stream?(stream_name)
    stream_name.to_s.split(":", 2).second == "messages"
  end

  def self.subscribable_stream?(user, stream_name)
    gid_param, suffix = stream_name.to_s.split(":", 2)
    return false unless suffix == "messages" && gid = GlobalID.parse(gid_param)
    return false unless (model = gid.model_class) <= Room && gid.model_id.is_a?(String)

    # Reference: reference/app/channels/room_messages_channel.rb. Combine room
    # existence and current membership in one query; the channel needs no model.
    Queries::Room.exists_for_user?(model: model, user_id: user.id, room_id: gid.model_id)
  end

  def subscribed
    stream_name = self.class.verified_stream_name(params[:signed_stream_name])
    if stream_name.present? && self.class.subscribable_stream?(current_user, stream_name)
      stream_from stream_name
    else
      reject
    end
  end
end
