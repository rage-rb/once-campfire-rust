# frozen_string_literal: true

class Room < ApplicationRecord
  plugin :single_table_inheritance, :type
  many_to_one :creator, class: :User
  one_to_many :memberships
  one_to_many :messages
  many_to_many :users, join_table: :memberships

  def self.create_for(attributes, users:)
    db.transaction do
      create(attributes).tap { |room| Membership.grant(room, users) }
    end
  end

  def before_validation
    self.creator ||= Current.user
    creator.save if creator&.new?
    super
  end

  def validate
    super
    if !new? && column_changed?(:type) && initial_value(:type) == "Rooms::Direct"
      errors.add(:type, "can't be changed for a direct room")
    end
  end

  def before_save
    @grant_open_access = (new? || column_changed?(:type)) && type == "Rooms::Open"
    super
  end

  def after_save
    super
    db.after_commit { Membership.grant(self, User.active.all) } if @grant_open_access
  end

  def open? = is_a?(Rooms::Open)
  def closed? = is_a?(Rooms::Closed)
  def direct? = is_a?(Rooms::Direct)
  def default_involvement = "mentions"

  def create_message(attributes)
    Message.create(attributes.to_h.symbolize_keys.merge(room: self)).tap(&:process_attachment)
  end

  # Reference: reference/app/models/room.rb; run from Message's after-commit hook.
  def receive(message)
    memberships_dataset.visible.disconnected.exclude(user_id: message.creator_id)
      .update(unread_at: message.created_at, updated_at: Time.current)
    BenchmarkPushMessage.enqueue(room_id: id, message_id: message.id)
  end
end
