# frozen_string_literal: true

class Queries::RichText < Queries::Base
  def self.fetch_for_message(message_id:)
    fetch_first(:for_message, message_id: message_id) do
      ::RichText.where(record_type: "Message", record_id: :$message_id, name: "body")
    end
  end
end
