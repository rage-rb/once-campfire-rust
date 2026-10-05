# frozen_string_literal: true

class PresenceChannel < RoomChannel
  after_subscribe :present, unless: :subscription_rejected?

  def present
    # Reuse the reference callback's lookup, but don't retain its mutable count
    # across later disconnect/refresh actions (reference/app/channels/presence_channel.rb).
    current_membership = membership
    @membership_id = current_membership.id
    if BenchmarkPresenceBatch.enabled?
      BenchmarkPresenceBatch.enqueue(@membership_id, :present)
    else
      current_membership.present
    end
    Rage::Cable.broadcast("user_#{current_user.id}_reads", { room_id: current_membership.room_id })
  end

  def unsubscribed
    return if subscription_rejected?

    if BenchmarkPresenceBatch.enabled?
      BenchmarkPresenceBatch.enqueue(@membership_id, :disconnected)
    else
      membership.disconnected
    end
  end

  def refresh
    if BenchmarkPresenceBatch.enabled?
      BenchmarkPresenceBatch.enqueue(@membership_id, :refresh)
    else
      membership.refresh_connection
    end
  end

  private
    def membership
      @room.memberships.find_by(user: current_user)
    end
end
