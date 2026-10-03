# frozen_string_literal: true

# Preserve the reference URL helpers used by message ERB. No request is dispatched to Rails.
load "#{CampfireBenchmark::REFERENCE}/config/routes.rb"
Rage.routes.draw do
  get "/up", to: "health#show"
  get "/", to: "benchmark_rooms#index"
  get "/session/new", to: "benchmark_sessions#new"
  post "/session", to: "benchmark_sessions#create"
  get "/rooms/:id", to: "benchmark_rooms#show"
  get "/users/me/sidebar", to: "benchmark_sidebars#show"
  post "/rooms/:room_id/messages", to: "benchmark_messages#create"
  mount Rage::Cable.application, at: "/cable"
end
