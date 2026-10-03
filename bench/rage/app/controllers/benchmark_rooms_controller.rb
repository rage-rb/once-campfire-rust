# frozen_string_literal: true

class BenchmarkRoomsController < BenchmarkController
  def index
    redirect_to "/rooms/#{Current.user.rooms.first!.id}"
  end

  def show
    room = Current.user.rooms.find(params[:id])
    html %(<meta name="csrf-token" content="benchmark-same-origin">#{stream_source("RoomMessagesChannel", room, :messages)})
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
