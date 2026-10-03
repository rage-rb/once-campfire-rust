# frozen_string_literal: true

module BenchmarkAuthentication
  # Rage's signed cookies use a different format. Keep Rails' actual jar so benchmark
  # preparation cookies can be shared with the reference and Rust implementation.
  def self.cookie_jar(env)
    request = ActionDispatch::Request.new(Rails.application.env_config.merge(env))
    request.cookie_jar
  end

  def self.session_for(env)
    if token = cookie_jar(env).signed[:session_token]
      Session.find_by(token: token)
    end
  end

  def self.set_cookie(env, headers, session)
    jar = cookie_jar(env)
    jar.signed.permanent[:session_token] = { value: session.token, httponly: true, same_site: :lax }
    response = Rack::Response.new([], 200, headers)
    jar.write(response)
    headers.merge!(response.headers)
  end
end
