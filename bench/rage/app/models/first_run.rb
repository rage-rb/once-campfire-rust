# frozen_string_literal: true

class FirstRun
  ACCOUNT_NAME = "Campfire"
  FIRST_ROOM_NAME = "All Talk"

  # Reference: reference/app/models/first_run.rb.
  def self.create!(attributes)
    Account.create(name: ACCOUNT_NAME)
    room = Rooms::Open.new(name: FIRST_ROOM_NAME)
    administrator = User.new(attributes.merge(role: :administrator))
    Room.db.transaction do
      administrator.save
      room.creator = administrator
      room.save
    end
    Membership.grant(room, [administrator])
    administrator
  end
end
