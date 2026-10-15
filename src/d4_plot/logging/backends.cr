require "log"

module D4Plot::Logging
  module StderrOutput
    @@mutex = Thread::Mutex.new

    def self.write(message : String) : Nil
      synchronize do
        STDERR.puts(message)
        STDERR.flush
      end
    rescue
      # A best-effort diagnostic must not become a second application failure.
    end

    def self.synchronize(& : -> Nil) : Nil
      @@mutex.synchronize { yield }
    end
  end

  struct TextFormatter < ::Log::StaticFormatter
    LOCAL_CAPABILITY_URL = %r{https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/[^\s"'<>]*}

    def run
      timestamp
      string " "
      severity
      pid
      source(before: " [", after: "] ")
      message
      data(before: " ")
      context(before: " ")
      exception
    end

    def self.format(entry : ::Log::Entry, io : IO) : Nil
      text = String.build { |buffer| new(entry, buffer).run }
      io << text.gsub(LOCAL_CAPABILITY_URL, "[local-url-redacted]")
    end
  end

  # Serializes log entries with direct CLI diagnostics written to stderr.
  class StderrBackend < ::Log::IOBackend
    def initialize(dispatcher : ::Log::Dispatcher)
      super(STDERR, formatter: TextFormatter, dispatcher: dispatcher)
    end

    def write(entry : ::Log::Entry) : Nil
      StderrOutput.synchronize { super }
    end
  end

  # Each process uses its own default file, so rotation never crosses process
  # boundaries. Rotation runs only on the dispatcher worker.
  class RotatingFileBackend < ::Log::IOBackend
    def initialize(@path : String, dispatcher : ::Log::Dispatcher,
                   @max_bytes : Int64 = 5_i64 * 1024 * 1024)
      Dir.mkdir_p(File.dirname(@path))
      super(File.open(@path, "a"), formatter: TextFormatter, dispatcher: dispatcher)
    end

    def write(entry : ::Log::Entry) : Nil
      rotate if io.pos >= @max_bytes
      super
    end

    def close : Nil
      super
      io.close
    end

    private def rotate : Nil
      io.close
      File.delete("#{@path}.2") if File.exists?("#{@path}.2")
      File.rename("#{@path}.1", "#{@path}.2") if File.exists?("#{@path}.1")
      File.rename(@path, "#{@path}.1")
      self.io = File.open(@path, "w")
    end
  end
end
