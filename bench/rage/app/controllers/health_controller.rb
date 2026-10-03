# frozen_string_literal: true

class HealthController < RageController::API
  def show
    head :ok
  end
end
