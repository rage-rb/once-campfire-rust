# frozen_string_literal: true

require_relative "boot"
require "rails/all"
Bundler.require(*Rails.groups)

module CampfireBenchmark
  REFERENCE = File.expand_path("../../../reference", __dir__)
  STORAGE = File.expand_path(ENV.fetch("CAMPFIRE_STORAGE_PATH", "../.work/rage/storage"), File.expand_path("..", __dir__))

  class Application < Rails::Application
    config.load_defaults 8.2
    config.root = File.expand_path("..", __dir__)
    config.paths.add "app/models", with: "#{REFERENCE}/app/models", eager_load: true
    config.paths.add "app/helpers", with: "#{REFERENCE}/app/helpers", eager_load: true
    config.paths["app/views"] = "#{REFERENCE}/app/views"
    config.paths["config/locales"] = "#{REFERENCE}/config/locales"
    config.autoload_paths << "#{REFERENCE}/lib"
    $LOAD_PATH.unshift "#{REFERENCE}/lib"
    config.autoload_lib(ignore: %w[assets tasks])
    config.i18n.fallbacks = true
    config.active_support.isolation_level = :fiber
    config.active_storage.service = :local
    config.active_storage.service_configurations = { "local" => { "service" => "Disk", "root" => "#{STORAGE}/files" } }
    config.cache_store = :memory_store
    config.action_controller.perform_caching = true
    config.action_controller.allow_forgery_protection = false
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
    config.assets.paths << "#{REFERENCE}/app/assets/images"
    config.assets.paths << "#{REFERENCE}/app/assets/stylesheets"
    config.assets.paths << "#{REFERENCE}/app/javascript"
    config.assets.paths << "#{REFERENCE}/vendor/javascript"
    config.assets.paths << "#{REFERENCE}/vendor/stylesheets"
    config.x.vapid.public_key = nil
    config.x.vapid.private_key = nil
    config.app_version = "rage-benchmark"
    config.git_revision = nil
    config.after_initialize do
      Rage.configure do
        config.logger = Rage::Logger.new($stdout)
        config.logger.level = Logger::Severity.const_get(ENV.fetch("RAGE_LOG_LEVEL", "warn").upcase)
        config.server.workers_count = 4
        config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
        config.deferred.backend = nil
      end
    end
  end
end

# Official Rails integration: require after defining Rails::Application.
require "rage/rails"
