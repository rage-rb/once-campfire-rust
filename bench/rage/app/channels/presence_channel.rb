# frozen_string_literal: true

class PresenceChannel < RoomChannel
  after_subscribe :present, unless: :subscription_rejected?

  def present
    membership.present
    Rage::Cable.broadcast("user_#{current_user.id}_reads", { room_id: membership.room_id })
  end

  def unsubscribed
    membership.disconnected unless subscription_rejected?
  end

  def refresh
    membership.refresh_connection
  end

  private
    def membership
      @room.memberships.find_by(user: current_user)
    end
end
