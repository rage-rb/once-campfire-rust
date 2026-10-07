# frozen_string_literal: true

Push::Subscription = Class.new(ApplicationRecord)
class Push::Subscription
  set_dataset :push_subscriptions
  many_to_one :user, class: "::User"
end
