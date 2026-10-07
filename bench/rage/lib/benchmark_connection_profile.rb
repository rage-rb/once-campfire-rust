# frozen_string_literal: true

require "fileutils"

# Opt-in instrumentation for the real Cable runtime. Each worker starts on its
# first socket and stops when the load host creates PROFILE_DIR/stop. No cookies,
# stream signatures, SQL bindings, or per-client identifiers are recorded.
module BenchmarkConnectionProfile
  class << self
    def install!(directory)
      @directory = File.expand_path(directory)
      FileUtils.mkdir_p(@directory)
      @mode = ENV.fetch("PROFILE_MODE", "cpu").to_sym
      raise ArgumentError, "PROFILE_MODE must be cpu or wall" unless %i[cpu wall].include?(@mode)

      @interval = Integer(ENV.fetch("PROFILE_INTERVAL", "1000"))
      @details = ENV.fetch("PROFILE_DETAILS", "1") != "0"
      wrap(Rage::Cable::Protocols::ActioncableV1Json.singleton_class, :on_open, "protocol.open", start: true)
      wrap(Rage::Cable::Protocols::ActioncableV1Json.singleton_class, :on_message, "protocol.message")
      install_details! if @details

      Iodine.on_state(:on_start) do
        @running = false
        @finished = false
        @timings = {}
        @sql = {}
        Iodine.run_every(50) do
          if @running && File.exist?(File.join(@directory, "stop")) && BenchmarkPresenceBatch.idle?
            finish!
          end
        end
      end
      Iodine.on_state(:on_finish) { finish! if @running }
    end

    def install_details!
      wrap(Rage::Cable::Router, :process_connection, "connection.authenticate")
      channel_argument = Rage::Cable::Router.instance_method(:process_subscription).parameters.index { |_, name| name == :channel_name }
      raise "Unknown Rage process_subscription arguments" unless channel_argument
      wrap(Rage::Cable::Router, :process_subscription) { |args| "subscription.#{args.fetch(channel_argument)}" }
      wrap(BenchmarkAuthentication.singleton_class, :session_for, "authentication.session")
      wrap(BenchmarkAuthentication.singleton_class, :user_for, "authentication.user")
      wrap(BenchmarkAuthentication.singleton_class, :cookie_jar, "authentication.cookie_jar")
      wrap(PresenceChannel, :present, "presence.callback")
      wrap(PresenceChannel, :membership, "presence.membership_lookup")
      wrap(Membership, :present, "presence.update")
      wrap(BenchmarkPresenceBatch, :flush, "presence.flush")
      wrap(RoomMessagesChannel.singleton_class, :subscribable_stream?, "room_messages.authorization")
      [RoomMessagesChannel, BenchmarkTurboStreamsChannel].each do |klass|
        wrap(klass.singleton_class, :verified_stream_name, "stream.verify_signature")
      end
      wrap(Rage::Cable::Protocols::ActioncableV1Json.singleton_class, :subscribe, "stream.subscribe")
      wrap(Rage::Cable::Protocols::ActioncableV1Json.singleton_class, :broadcast, "stream.broadcast")

      ActiveSupport::Notifications.monotonic_subscribe("sql.sequel") do |_, started, finished, _, payload|
        stack = Fiber[:benchmark_connection_profile]
        next unless @running && stack&.any?

        # Notification duration includes SQLite waits. Exclude schema setup.
        owner = stack.last[:label]
        operation = payload[:sql].to_s.split.first.to_s.upcase
        label = "#{owner} / Sequel / #{operation}"
        (@sql[label] ||= []) << (finished - started) * 1000
      end
    end

    def wrap(target, method, label = nil, start: false, &labeler)
      wrapper = Module.new do
        define_method(method) do |*args, **kwargs, &block|
          BenchmarkConnectionProfile.start! if start
          name = label || labeler.call(args)
          BenchmarkConnectionProfile.measure(name) { super(*args, **kwargs, &block) }
        end
      end
      target.prepend(wrapper)
    end

    def start!
      return if @running || @finished

      @running = true
      @started_at = Time.now.utc.iso8601(6)
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @cpu_started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      @gc_started = GC.stat
      StackProf.start(mode: @mode, interval: @interval, raw: true)
    end

    def measure(label)
      return yield unless @running

      stack = Fiber[:benchmark_connection_profile] ||= []
      frame = { label: label, children: 0.0 }
      stack << frame
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        yield
      ensure
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        stack.pop
        stack.last[:children] += elapsed if stack.any?
        row = (@timings[label] ||= { wall: [], self_wall: [] })
        row[:wall] << elapsed
        row[:self_wall] << elapsed - frame[:children]
      end
    end

    def distribution(values)
      sorted = values.sort
      { count: sorted.size, total_ms: sorted.sum, mean_ms: sorted.sum / sorted.size,
        p50_ms: sorted[(sorted.size - 1) / 2], p95_ms: sorted[((sorted.size - 1) * 0.95).ceil], max_ms: sorted.last }
    end

    def finish!
      @running = false
      @finished = true
      StackProf.stop
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
      cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - @cpu_started
      gc = GC.stat
      prefix = File.join(@directory, "worker-#{Process.pid}")
      StackProf.results("#{prefix}.dump")
      summary = { pid: Process.pid, started_at: @started_at, elapsed_secs: elapsed, cpu_secs: cpu,
        mode: @mode, interval_us: @interval, details: @details, yjit: RubyVM::YJIT.enabled?,
        gc: %i[count minor_gc_count major_gc_count total_allocated_objects time].to_h { |key| [key, gc[key] - @gc_started[key]] },
        timings: @timings.transform_values { |row| { wall: distribution(row[:wall]), self_wall: distribution(row[:self_wall]) } },
        sql: @sql.transform_values { |values| distribution(values) } }
      File.write("#{prefix}.json", JSON.pretty_generate(summary) + "\n")
    end
  end
end
