# frozen_string_literal: true

# Only an Action View host. HTTP is handled by BenchmarkController through Rage.
class BenchmarkRendererController < ActionController::Base
  helper :all
  include Rails.application.routes.url_helpers
  self.perform_caching = true
end
