# frozen_string_literal: true

class BenchmarkSessionsController < BenchmarkController
  skip_before_action :require_authentication

  def new
    html '<meta name="csrf-token" content="benchmark-same-origin"><form action="/session" method="post"><input name="email_address"><input name="password" type="password"></form>'
  end

  def create
    if user = User.active.authenticate_by(email_address: params[:email_address], password: params[:password])
      session = user.start_session(user_agent: request.user_agent, ip_address: Current.request.remote_ip)
      BenchmarkAuthentication.set_cookie(request.env, headers, session)
      redirect_to "/"
    else
      head :unauthorized
    end
  end
end
