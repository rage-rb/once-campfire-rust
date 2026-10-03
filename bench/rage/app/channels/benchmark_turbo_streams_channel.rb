# frozen_string_literal: true

class BenchmarkTurboStreamsChannel < ApplicationChannel
  extend Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def subscribed
    stream_name = self.class.verified_stream_name(params[:signed_stream_name])
    if stream_name.present? && !RoomMessagesChannel.guarded_stream?(stream_name)
      stream_from stream_name
    else
      reject
    end
  end
end
