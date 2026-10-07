# frozen_string_literal: true

class Room::MessagePusher
  attr_reader :room, :message

  def initialize(room:, message:)
    @room, @message = room, message
  end

  # Reference: reference/app/models/room/message_pusher.rb. Keep both recipient
  # queries and payload construction even when the benchmark has no recipients.
  def push
    payload = if room.direct?
      { title: message.creator.name, body: message.plain_text_body, path: Rails.application.routes.url_helpers.room_path(room) }
    else
      { title: room.name, body: "#{message.creator.name}: #{message.plain_text_body}", path: Rails.application.routes.url_helpers.room_path(room) }
    end
    Rails.configuration.x.web_push_pool.queue(payload, relevant_subscriptions.where(Sequel[:memberships][:involvement] => "everything"))
    Rails.configuration.x.web_push_pool.queue(payload, relevant_subscriptions.where(Sequel[:memberships][:involvement] => "mentions")
      .where(Sequel[:push_subscriptions][:user_id] => message.mentionees.select_map(Sequel[:users][:id])))
    payload
  end

  private
    def relevant_subscriptions
      Push::Subscription.join(:users, id: :user_id)
        .join(:memberships, user_id: Sequel[:users][:id])
        .where(Sequel[:memberships][:room_id] => room.id)
        .exclude(Sequel[:memberships][:user_id] => message.creator_id)
        .exclude(Sequel[:memberships][:involvement] => "invisible")
        .where(Sequel.|({ Sequel[:memberships][:connected_at] => nil }, Sequel[:memberships][:connected_at] < Membership::CONNECTION_TTL.ago))
        .select_all(:push_subscriptions)
    end
end
