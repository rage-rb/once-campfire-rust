# frozen_string_literal: true

class BenchmarkSidebarsController < BenchmarkController
  def show
    html stream_source("Turbo::StreamsChannel", :rooms) + stream_source("Turbo::StreamsChannel", Current.user, :rooms)
  end
end
