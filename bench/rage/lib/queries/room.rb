# frozen_string_literal: true

class Queries::Room < Queries::Base
  def self.fetch_for_user(user_id:, room_id:)
    fetch_first(:for_user, user_id: user_id, room_id: room_id) do
      for_user.where(Sequel[:rooms][:id] => :$room_id)
    end
  end

  def self.fetch_first_for_user(user_id:)
    fetch_first(:first_for_user, user_id: user_id) { for_user }
  end

  def self.for_user
    ::Room.join(:memberships, room_id: :id)
      .where(Sequel[:memberships][:user_id] => :$user_id).select_all(:rooms)
  end
  private_class_method :for_user
end
