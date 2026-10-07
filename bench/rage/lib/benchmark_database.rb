# frozen_string_literal: true

require "sequel"
require "fileutils"
require "yaml"
require "erb"
require "digest"

module BenchmarkDatabase
  Sequel.extension :fiber_concurrency, :datetime_parse_to_time
  Sequel.datetime_class = Time
  Sequel.default_timezone = :utc

  module PreparedStatements
    private
      def execute_prepared_statement(connection, type, name, options, &block)
        super
      ensure
        # :first returns before SQLITE_DONE. The pinned adapter clears bindings
        # but does not reset the cursor, retaining a read snapshot between calls.
        statement = connection.prepared_statements[name]&.first
        statement.reset! if statement && !statement.closed?
      end
  end

  module Instrumentation
    # As with Rails SQL notifications, profiling and acceptance tests can observe
    # queries without configuring a logger or changing database access.
    def log_connection_yield(sql, *args, &block)
      # Sequel logs executions by statement name. Expose their parameterized SQL
      # so existing observers still count SELECTs, separately from PREPARE work.
      statement = prepared_statement(sql.split(" ", 3)[1].to_sym) if sql.start_with?("EXECUTE ")
      notification_sql = statement ? statement.prepared_sql : sql
      ActiveSupport::Notifications.instrument("sql.sequel", sql: notification_sql) { super }
    end
  end

  def self.connect
    settings = YAML.safe_load(ERB.new(File.read(File.expand_path("../config/database.yml", __dir__))).result, aliases: true).fetch(ENV.fetch("RAILS_ENV", "development"))
    path = settings.fetch("database")
    FileUtils.mkdir_p(File.dirname(path))
    database = Sequel.sqlite(path, max_connections: settings.fetch("pool"), timeout: settings.fetch("timeout"),
      foreign_keys: true, synchronous: :normal,
      after_connect: ->(connection) do
        # The pinned Rails SQLite adapter uses this GVL-releasing busy handler.
        connection.busy_handler_timeout = settings.fetch("timeout")
        connection.execute_batch("PRAGMA journal_mode = WAL; PRAGMA journal_size_limit = 67108864; PRAGMA cache_size = 2000;")
      end)
    database.transaction_mode = settings.fetch("default_transaction_mode").to_sym
    database.extend(PreparedStatements)
    database.extend(Instrumentation)
    database
  end

  def self.prepare(database)
    return if database.table_exists?(:users)
    raise ArgumentError, "Cannot prepare a partially populated database" unless database.tables.empty?

    # The Rust port's sqlite_master snapshot comes from reference/db/schema.rb.
    # Reuse it verbatim, including constraints, indexes and the Porter FTS table.
    database.transaction do
      database.synchronize do |connection|
        connection.execute_batch(File.read(File.expand_path("../../../crates/db/src/schema.sql", __dir__)))
      end
      versions = Dir["#{CampfireBenchmark::REFERENCE}/db/migrate/*.rb"].map { |path| File.basename(path).split("_").first }
      database[:schema_migrations].multi_insert(versions.map { |version| { version: version } })
      metadata = {
        "environment" => ENV.fetch("RAILS_ENV", "development"),
        "schema_sha1" => Digest::SHA1.file("#{CampfireBenchmark::REFERENCE}/db/schema.rb").hexdigest
      }
      now = Time.current
      database[:ar_internal_metadata].multi_insert(metadata.map { |key, value| { key: key, value: value, created_at: now, updated_at: now } })
    end
  end
end
