# frozen_string_literal: true

class BenchmarkController < RageController::API
  before_action :set_current_request
  before_action :require_authentication

  private
    def set_current_request
      Current.request = ActionDispatch::Request.new(request.env)
    end

    def require_authentication
      if session = BenchmarkAuthentication.session_for(request.env)
        session.resume(user_agent: request.user_agent, ip_address: Current.request.remote_ip)
        Current.session = session
        BenchmarkAuthentication.set_cookie(request.env, headers, session)
      else
        redirect_to "/session/new"
      end
    end

    def redirect_to(path)
      headers["location"] = path
      head :found
    end

    def html(body, status: :ok)
      render plain: body, status: status
      headers["content-type"] = "text/html; charset=utf-8"
    end

    def stream_source(channel, *streamables)
      name = Turbo::StreamsChannel.signed_stream_name(streamables)
      %(<turbo-cable-stream-source channel="#{channel}" signed-stream-name="#{ERB::Util.html_escape(name)}"></turbo-cable-stream-source>)
    end
end
