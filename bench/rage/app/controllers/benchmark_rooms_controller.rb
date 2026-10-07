# frozen_string_literal: true

class BenchmarkRoomsController < BenchmarkController
  def index
    redirect_to "/rooms/#{Current.user.first_room!.id}"
  end

  def show
    room = Current.user.find_room!(params[:id].to_i)
    html %(<meta name="csrf-token" content="benchmark-same-origin">#{stream_source("RoomMessagesChannel", room, :messages)})
  rescue Sequel::NoMatchingRow
    head :not_found
  end
end
