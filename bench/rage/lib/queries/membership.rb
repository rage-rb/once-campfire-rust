# frozen_string_literal: true

class Queries::Membership < Queries::Base
  def self.fetch_for_user(room_id:, user_id:)
    fetch_first(:for_user, room_id: room_id, user_id: user_id) do
      ::Membership.where(room_id: :$room_id, user_id: :$user_id)
    end
  end
end
