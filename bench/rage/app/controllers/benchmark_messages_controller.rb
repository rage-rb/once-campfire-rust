# frozen_string_literal: true

class BenchmarkMessagesController < BenchmarkController
  def create
    # Reference: app/controllers/messages_controller.rb and RoomScoped. Attachments
    # are outside this text-message benchmark and intentionally not accepted.
    room = Current.user.find_room!(params[:room_id].to_i)
    message = room.create_message(params.require(:message).permit(:body, :client_message_id))
    message.broadcast_create
    bots = room.direct? ? room.users_dataset.active_bots : message.mentionees.active_bots
    bots.exclude(Sequel[:users][:id] => message.creator_id).each { raise "Benchmark dataset must have no bots" }
    render plain: BenchmarkMessageRendering.response(message)
    headers["content-type"] = "text/vnd.turbo-stream.html; charset=utf-8"
  rescue Sequel::NoMatchingRow
    head :not_found
  end
end
