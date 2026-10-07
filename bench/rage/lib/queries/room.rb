# frozen_string_literal: true

class Queries::Room < Queries::Base
  def self.exists_for_user?(model:, user_id:, room_id:)
    types = model.sti_key_array
    types = Sequel.synchronize { types.dup.freeze } if types
    !!fetch_first(model, version: types, user_id: user_id, room_id: room_id.to_s.to_i) do
      # Snapshot the signed model's STI filter, as in Queries::Record, but return
      # only authorization rather than instantiating either reference Room read.
      scope = model.sti_dataset
      scope = scope.where(Sequel[:rooms][model.sti_key] => types) if types
      scope.join(:memberships, room_id: :id)
        .where(Sequel[:rooms][:id] => :$room_id, Sequel[:memberships][:user_id] => :$user_id)
        .select(Sequel.as(1, :authorized)).with_row_proc(nil)
    end
  end

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
