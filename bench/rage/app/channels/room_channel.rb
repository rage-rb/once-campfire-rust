# frozen_string_literal: true

class RoomChannel < ApplicationChannel
  def subscribed
    if @room = current_user.rooms.find_by(id: params[:room_id])
      stream_for @room
    else
      reject
    end
  end
end
