# frozen_string_literal: true

class BenchmarkPresenceBatch
  INTERVAL_MS = Integer(ENV.fetch("BENCHMARK_PRESENCE_BATCH_MS", "100"))
  raise ArgumentError, "BENCHMARK_PRESENCE_BATCH_MS must be nonnegative" if INTERVAL_MS.negative?

  class << self
    def enabled? = INTERVAL_MS.positive?
    def enqueue(...) = queue.enqueue(...)
    def flush = queue.flush
    def idle? = queue.idle?

    private
      def queue
        @queue ||= new
      end
  end

  def initialize
    @pending = {}
    @flushing = false
  end

  def enqueue(membership_id, action, at: Time.current)
    raise ArgumentError, "Unknown presence action: #{action}" unless %i[present disconnected refresh].include?(action)

    (@pending[membership_id] ||= []) << [action, at]
  end

  def idle?
    @pending.empty? && !@flushing
  end

  def flush
    return if @flushing || @pending.empty?

    batch = @pending
    @pending = {}
    @flushing = true
    begin
      # config/database.yml uses BEGIN IMMEDIATE. Acquire the SQLite write lock
      # before reading counts, so separate workers cannot overwrite each other.
      Membership.transaction do
        rows = Membership.where(id: batch.keys).pluck(:id, :connections, :connected_at, :unread_at, :updated_at)
        rows.each { |row| replay(row, batch.fetch(row.first)) }
        write(rows) if rows.any?
      end
    rescue
      # The database transaction rolled back. Keep its events ahead of any that
      # arrived while the flush yielded; the daemon can retry after restarting.
      batch.each { |id, events| @pending[id] = events.concat(@pending.fetch(id, [])) }
      raise
    ensure
      @flushing = false
    end
  end

  private
    def replay(row, events)
      # Reference: reference/app/models/membership/connectable.rb. Replay each
      # worker's ordered events against the latest persisted row, rather than
      # retaining channel model objects or writing worker-local absolute counts.
      events.each do |action, at|
        connected = row[2] && row[2] >= at - Membership::CONNECTION_TTL
        case action
        when :present
          row[1] = connected ? row[1] + 1 : 1
          row[2] = [row[2], at].compact.max
          row[3] = nil
        when :disconnected
          row[1] = connected ? row[1] - 1 : 0
          row[2] = nil if row[1] < 1
          row[4] = [row[4], at].compact.max
        when :refresh
          row[1] = 1 unless connected
          row[2] = [row[2], at].compact.max
          row[4] = [row[4], at].compact.max
        end
      end
    end

    def write(rows)
      database = Membership.connection
      assignments = %w[connections connected_at unread_at updated_at].each_with_index.map do |column, index|
        cases = rows.map { |row| "WHEN #{database.quote(row[0])} THEN #{database.quote(row[index + 1])}" }.join(" ")
        "#{column} = CASE id #{cases} END"
      end
      Membership.where(id: rows.map(&:first)).update_all(assignments.join(", "))
    end
end
