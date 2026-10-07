# frozen_string_literal: true

# A separate process boots the pinned Rails models; no Sequel model can leak into
# the reference renderer or replace its callbacks. It reads the test-owned DB.
ENV["BUNDLE_GEMFILE"] = File.expand_path("../Gemfile", __dir__)
ENV["RAILS_ENV"] = "test"
require "bundler/setup"
require "rails/all"
Bundler.require(*Rails.groups)
require "tmpdir"
require "json"

module ReferenceProbe
  REFERENCE = File.expand_path("../../../reference", __dir__)
  class Application < Rails::Application
    config.load_defaults 8.2
    config.root = Dir.mktmpdir("campfire-reference-probe-")
    config.define_singleton_method(:database_configuration) do
      { "test" => { "adapter" => "sqlite3", "database" => ARGV.fetch(0) } }
    end
    config.enable_reloading = false
    config.eager_load = false
    config.paths.add "app/models", with: "#{REFERENCE}/app/models", eager_load: true
    config.paths.add "app/helpers", with: "#{REFERENCE}/app/helpers", eager_load: true
    config.paths["app/views"] = "#{REFERENCE}/app/views"
    config.paths["config/locales"] = "#{REFERENCE}/config/locales"
    config.paths["config/routes.rb"] = "#{REFERENCE}/config/routes.rb"
    config.autoload_paths << "#{REFERENCE}/lib"
    $LOAD_PATH.unshift "#{REFERENCE}/lib"
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
    config.cache_store = :memory_store
    config.action_controller.perform_caching = true
    config.action_controller.allow_forgery_protection = false
    config.active_storage.service = :local
    config.active_storage.service_configurations = { "local" => { "service" => "Disk", "root" => "#{config.root}/files" } }
    config.assets.paths << "#{REFERENCE}/app/assets/images"
    config.assets.paths << "#{REFERENCE}/app/assets/stylesheets"
    config.assets.paths << "#{REFERENCE}/app/javascript"
    config.assets.paths << "#{REFERENCE}/vendor/javascript"
    config.assets.paths << "#{REFERENCE}/vendor/stylesheets"
    config.x.vapid.public_key = nil
    config.x.vapid.private_key = nil
    config.app_version = "rage-benchmark"
    config.git_revision = nil
    initializer "reference_probe.presentation" do
      Dir["#{REFERENCE}/lib/rails_ext/*.rb"].sort.each { |path| require path }
      Time::DATE_FORMATS[:epoch] = ->(time) { (time.to_f * 1000).to_i }
    end
  end
end

at_exit do
  ActiveRecord::Base.connection_pool.disconnect!
  FileUtils.remove_entry(ReferenceProbe::Application.config.root)
end

Rails.application.initialize!
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ARGV.fetch(0))
GlobalID.app = "campfire"

class ProbeRendererController < ActionController::Base
  helper :all
  include Rails.application.routes.url_helpers
  self.perform_caching = true
end

message = Message.find(ARGV.fetch(1))
Current.user = message.creator
html = ProbeRendererController.renderer.new(http_host: "localhost:4555").render(
  formats: [:turbo_stream], inline: '<%= turbo_stream.append dom_id(message.room, :messages), message %>', locals: { message: message })
puts JSON.generate(html: html, body: message.body.body.to_html, plain_text: message.plain_text_body,
  avatar_token: message.creator.avatar_token, room_gid: message.room.to_gid_param,
  user_role: message.creator.role, user_status: message.creator.status)
