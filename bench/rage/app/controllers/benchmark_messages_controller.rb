# frozen_string_literal: true

class BenchmarkMessagesController < BenchmarkController
  def create
    # Reference: app/controllers/messages_controller.rb and RoomScoped. Attachments
    # are outside this text-message benchmark and intentionally not accepted.
    room = Current.user.rooms.find(params[:room_id])
    message = room.messages.create_with_attachment!(params.require(:message).permit(:body, :client_message_id))
    message.broadcast_create
    bots = room.direct? ? room.users.active_bots : message.mentionees.active_bots
    bots.excluding(message.creator).each { |bot| bot.deliver_webhook_later(message) }
    render plain: BenchmarkMessageRendering.response(message)
    headers["content-type"] = "text/vnd.turbo-stream.html; charset=utf-8"
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
