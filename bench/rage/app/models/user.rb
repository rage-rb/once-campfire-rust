# frozen_string_literal: true

class User < ApplicationRecord
  include ActiveModel::SecurePassword
  has_secure_password validations: false, reset_token: false
  include ActionText::Attachable

  one_to_many :memberships
  one_to_many :sessions
  many_to_many :rooms, join_table: :memberships

  ROLES = { member: 0, administrator: 1, bot: 2 }.freeze
  STATUSES = { active: 0, deactivated: 1, banned: 2 }.freeze
  ROLES.each do |name, value|
    define_method("#{name}?") { self[:role] == value }
  end
  STATUSES.each do |name, value|
    define_method("#{name}?") { self[:status] == value }
  end
  def role = ROLES.key(self[:role])&.to_s
  def status = STATUSES.key(self[:status])&.to_s

  def role=(value)
    self[:role] = value.is_a?(Integer) ? value : ROLES.fetch(value.to_sym)
  end

  def status=(value)
    self[:status] = value.is_a?(Integer) ? value : STATUSES.fetch(value.to_sym)
  end

  dataset_module do
    def active = where(status: 0)
    def active_bots = active.where(role: 2)
    def without_bots = exclude(role: 2)
    def ordered = order(Sequel.function(:lower, :name))
    def authenticate_by(email_address:, password:)
      return if password.nil? || password.empty?
      user = if self == model.active
        Queries::User.fetch_active_by_email(email_address: email_address)
      else
        first(email_address: email_address)
      end
      if user
        user if user.authenticate(password)
      else
        model.new(password: password) # Reference timing protection for missing users.
        nil
      end
    end
  end

  def find_room(id)
    Queries::Room.fetch_for_user(user_id: self.id, room_id: id)
  end

  def find_room!(id)
    find_room(id) || raise(Sequel::NoMatchingRow.new(rooms_dataset))
  end

  def first_room!
    Queries::Room.fetch_first_for_user(user_id: id) || raise(Sequel::NoMatchingRow.new(rooms_dataset))
  end

  # Reference: reference/app/models/user.rb, grant_membership_to_open_rooms.
  def after_create
    super
    db.after_commit do
      now = Time.current
      rows = Rooms::Open.select_map(:id).map { |room_id| { room_id: room_id, user_id: id, created_at: now, updated_at: now } }
      Membership.dataset.insert_conflict.multi_insert(rows) unless rows.empty?
    end
  end

  def start_session(user_agent:, ip_address:)
    Session.create(user: self, user_agent: user_agent, ip_address: ip_address)
  end

  def initials = name.scan(/\b\w/).join
  def title = [name, bio].compact_blank.join(" – ")
  def can_administer?(record = nil) = administrator? || self == record&.creator || record&.new_record?

  # Reference: User::Avatar and ActiveRecord::SignedId. Keep existing avatar URLs.
  def avatar_token
    Rails.application.message_verifier("active_record/signed_id").generate(id, purpose: "user/avatar")
  end

  MENTION_CONTENT_TYPE = "application/vnd.campfire.mention"
  def attachable_content_type = MENTION_CONTENT_TYPE
  def to_attachable_partial_path = "users/mention"
  def attachable_plain_text_representation(caption) = "@#{name}"
end
