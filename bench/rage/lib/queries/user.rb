# frozen_string_literal: true

class Queries::User < Queries::Base
  def self.fetch_active_by_email(email_address:)
    fetch_first(:active_by_email, email_address: email_address) do
      # SQLite IS also preserves the preceding IS NULL lookup for nil email.
      ::User.active.where(Sequel.lit("email_address IS ?", :$email_address))
    end
  end

  def self.fetch_by_session_token(token:)
    fetch_first(:by_session_token, token: token) do
      ::User.join(:sessions, user_id: :id)
        .where(Sequel[:sessions][:token] => :$token).select_all(:users)
    end
  end
end
