# frozen_string_literal: true

module RageCable
  class Connection < Rage::Cable::Connection
    identified_by :current_user

    def connect
      self.current_user = BenchmarkAuthentication.user_for(request.env)
      reject_unauthorized_connection unless current_user
    end
  end
end
