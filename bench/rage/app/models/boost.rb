# frozen_string_literal: true

class Boost < ApplicationRecord
  many_to_one :message
  many_to_one :booster, class: :User
  dataset_module do
    # Action View's cached collection renderer expects a materialized collection.
    def ordered = order(:created_at).all
  end

  def before_validation
    self.booster ||= Current.user
    super
  end

  def after_save
    super
    message.touch
  end

  def after_destroy
    super
    message.touch
  end
end
