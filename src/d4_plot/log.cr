require "log"
require "path"
require "./logging/backends"
require "./logging/non_blocking_dispatcher"

module D4Plot
  Log = ::Log.for("d4_plot")

  # Application-wide logging configuration and small logging helpers.
  #
  # Crystal's Log owns filtering, sources, entries and metadata. The custom
  # components only keep native UI callbacks away from yielding and file I/O.
  module Logging
    # Closing the backend waits for its worker and may resume on another OS thread.
    @@lifecycle_mutex = Sync::Mutex.new
    @@backend : ::Log::Backend?
    @@correlation_ids = Atomic(Int64).new(0)

    def self.next_correlation_id : Int64
      @@correlation_ids.add(1) + 1
    end

    def self.elapsed_ms(started : Time::Instant) : Float64
      (Time.instant - started).total_milliseconds.round(2)
    end

    # Direct CLI diagnostics and log entries share the same lock, preventing
    # partial lines when the log worker also writes to stderr.
    def self.write_stderr(message : String) : Nil
      StderrOutput.write(message)
    end

    # Capture exception state on the thread where it happened. Passing the
    # mutable Exception object to the asynchronous dispatcher would defer
    # backtrace inspection to another OS thread.
    def self.report_exception(log : ::Log, event : String, error : Exception, **fields) : Nil
      report_exception_at(log, event, error, ::Log::Severity::Error, fields)
    end

    def self.report_warning(log : ::Log, event : String, error : Exception, **fields) : Nil
      report_exception_at(log, event, error, ::Log::Severity::Warn, fields)
    end

    def self.report_fatal(log : ::Log, event : String, error : Exception, **fields) : Nil
      report_exception_at(log, event, error, ::Log::Severity::Fatal, fields)
    end

    private def self.report_exception_at(log, event, error, severity, fields) : Nil
      data = ::Log::Metadata.build(fields).extend({error_class: error.class.name})
      case severity
      when .warn?
        log.warn &.emit(event, data)
      when .fatal?
        log.fatal &.emit(event, data)
      else
        log.error &.emit(event, data)
      end
      log.debug do |entry|
        detail = ::Log::Metadata.build(fields).extend({exception_detail: exception_detail(error)})
        entry.emit("#{event}.detail", detail)
      end
    end

    private def self.exception_detail(error : Exception) : String
      String.build { |io| error.inspect_with_backtrace(io) }
    rescue exception
      "#{error.class.name} (backtrace unavailable: #{exception.class.name})"
    end

    def self.default_file_path : String
      {% if flag?(:win32) %}
        base = absolute_environment_directory("LOCALAPPDATA", "APPDATA") || Path.home.to_s
        File.join(base, "D4 Plot", "logs", "d4-plot-#{Process.pid}.log")
      {% elsif flag?(:darwin) %}
        File.join(Path.home, "Library", "Logs", "D4 Plot", "d4-plot-#{Process.pid}.log")
      {% else %}
        base = absolute_environment_directory("XDG_STATE_HOME") || File.join(Path.home, ".local", "state")
        File.join(base, "d4-plot", "logs", "d4-plot-#{Process.pid}.log")
      {% end %}
    end

    # State-directory variables must be absolute. An empty or relative value
    # would otherwise place diagnostic logs under the process working directory.
    private def self.absolute_environment_directory(*names : String) : String?
      names.each do |name|
        if value = ENV[name]?
          return value if !value.empty? && Path.new(value).absolute?
        end
      end
      nil
    end

    # Configure once during entry-point startup, before application workers
    # begin. Runtime reconfiguration is intentionally unsupported.
    def self.setup(desktop : Bool = false) : Nil
      @@lifecycle_mutex.synchronize do
        raise "Logging is already configured" if @@backend

        dispatcher = NonBlockingDispatcher.new
        backend : ::Log::Backend? = nil
        begin
          backend = build_backend(dispatcher, desktop)
          configure(backend)
          @@backend = backend
        rescue ex
          if backend
            backend.close
          else
            dispatcher.close
          end
          raise ex
        end

        Log.info &.emit("app.started", mode: desktop ? "desktop" : "server",
          crystal: Crystal::VERSION, version: {{ read_file("#{__DIR__}/../../shard.yml").split("version: ")[1].lines.first }},
          platform: {{ flag?(:win32) ? "windows" : (flag?(:darwin) ? "macos" : "unix") }})
      end
    end

    # Call only after producers have stopped. Clearing bindings before closing
    # also prevents Log's at_exit hook from closing this backend a second time.
    def self.close : Nil
      @@lifecycle_mutex.synchronize do
        backend = @@backend
        return unless backend

        Log.info { "app.stopped" }
        ::Log.builder.clear
        @@backend = nil
        backend.close
      end
    end

    private def self.build_backend(dispatcher : NonBlockingDispatcher, desktop : Bool) : ::Log::Backend
      path = ENV["D4_PLOT_LOG_FILE"]?.presence || (desktop ? default_file_path : nil)
      return StderrBackend.new(dispatcher) unless path

      RotatingFileBackend.new(path, dispatcher)
    rescue ex : IO::Error
      write_stderr("d4-plot: could not open log file (#{ex.class.name}); using stderr")
      StderrBackend.new(dispatcher)
    end

    private def self.configure(backend : ::Log::Backend) : Nil
      ::Log.setup_from_env(default_sources: "d4_plot.*", backend: backend)
    rescue ArgumentError
      ::Log.setup("d4_plot.*", :info, backend)
      Log.warn { "log.invalid_level; using INFO" }
    end
  end
end
