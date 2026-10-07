# frozen_string_literal: true

class Account < ApplicationRecord
  # Reference: reference/app/models/account/joinable.rb.
  def before_create
    self.join_code = SecureRandom.alphanumeric(12).scan(/.{4}/).join("-")
    super
  end

  def reset_join_code
    update(join_code: SecureRandom.alphanumeric(12).scan(/.{4}/).join("-"))
  end
end
