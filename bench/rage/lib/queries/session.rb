# frozen_string_literal: true

class Queries::Session < Queries::Base
  def self.fetch_by_token(token:)
    fetch_first(:by_token, token: token) { ::Session.where(token: :$token) }
  end
end
