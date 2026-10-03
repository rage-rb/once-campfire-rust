# frozen_string_literal: true

class UnreadRoomsChannel < ApplicationChannel
  def subscribed
    stream_for current_user.id
  end
end
