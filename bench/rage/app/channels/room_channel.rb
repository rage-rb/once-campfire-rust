# frozen_string_literal: true

class RoomChannel < ApplicationChannel
  def subscribed
    if @room = current_user.find_room(params[:room_id].to_i)
      stream_for @room
    else
      reject
    end
  end
end
