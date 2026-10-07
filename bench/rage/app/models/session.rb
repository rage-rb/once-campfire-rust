# frozen_string_literal: true

class Session < ApplicationRecord
  ACTIVITY_REFRESH_RATE = 1.hour
  many_to_one :user

  # Reference: reference/app/models/session.rb and Rails has_secure_token.
  def initialize(*args)
    super
    self.token ||= SecureRandom.base58(24)
  end

  def before_create
    self.last_active_at ||= Time.now
    super
  end

  def resume(user_agent:, ip_address:)
    if last_active_at < ACTIVITY_REFRESH_RATE.ago
      update(user_agent: user_agent, ip_address: ip_address, last_active_at: Time.now)
    end
  end
end
