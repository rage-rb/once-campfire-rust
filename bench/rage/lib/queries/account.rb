# frozen_string_literal: true

class Queries::Account < Queries::Base
  def self.fetch
    fetch_first(:first) { ::Account.dataset }
  end
end
