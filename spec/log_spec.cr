require "./spec_helper"
require "log/spec"
require "../src/d4_plot/file_loader"
require "../src/d4_plot/conversion_worker"
require "../src/d4_plot/igv_web_server"

private class LogGate
  @mutex = Thread::Mutex.new
  @wake = Thread::ConditionVariable.new
  @released = false

  def wait
    @mutex.synchronize do
      until @released
        @wake.wait(@mutex)
      end
    end
  end

  def release
    @mutex.synchronize do
      @released = true
      @wake.signal
    end
  end
end

private class SlowLogBackend < Log::Backend
  getter entries = [] of Log::Entry

  def initialize(dispatcher, @entered : Channel(Nil), @gate : LogGate)
    super(dispatcher)
  end

  def write(entry : Log::Entry) : Nil
    if @entries.empty?
      @entered.send(nil)
      @gate.wait
    end
    @entries << entry
  end
end

private class CollectingLogBackend < Log::Backend
  getter entries = [] of Log::Entry

  def initialize(dispatcher)
    super(dispatcher)
  end

  def write(entry : Log::Entry) : Nil
    @entries << entry
  end
end

private class BrokenLogIO < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("simulated full disk")
  end
end

describe D4Plot::Logging do
  {% unless flag?(:win32) || flag?(:darwin) %}
    it "ignores empty and relative XDG state directories" do
      previous = ENV["XDG_STATE_HOME"]?
      fallback = File.join(Path.home, ".local", "state", "d4-plot", "logs", "d4-plot-#{Process.pid}.log")
      begin
        ENV["XDG_STATE_HOME"] = ""
        D4Plot::Logging.default_file_path.should eq(fallback)

        ENV["XDG_STATE_HOME"] = "relative-state"
        D4Plot::Logging.default_file_path.should eq(fallback)
      ensure
        if previous
          ENV["XDG_STATE_HOME"] = previous
        else
          ENV.delete("XDG_STATE_HOME")
        end
      end
    end
  {% end %}

  it "uses standard filtering and keeps exception details out of INFO" do
    builder = Log::Builder.new
    backend = Log::MemoryBackend.new
    Log.setup("d4_plot.*", :info, backend, builder: builder)
    logger = builder.for("d4_plot.test")
    exception = ArgumentError.new("private/sample.d4 chr1:1-20")
    D4Plot::Logging.report_exception(logger, "read.failed", exception, request_id: 42)
    backend.entries.size.should eq(1)
    entry = backend.entries.first
    entry.data[:request_id].should eq(Log::Metadata::Value.new(42))
    entry.data[:error_class].to_s.should contain("ArgumentError")
    entry.exception.should be_nil
    entry.message.should eq("read.failed")

    Log.setup("d4_plot.*", :debug, backend, builder: builder)
    D4Plot::Logging.report_exception(logger, "read.failed", exception, request_id: 43)
    detail = backend.entries.last
    detail.exception.should be_nil
    detail.data[:exception_detail].to_s.should contain("private/sample.d4")
  end

  it "redacts capability URLs in metadata and exception details" do
    token = "secret-viewer-token"
    entry = Log::Entry.new("d4_plot.web", :debug, "request.failed",
      Log::Metadata.build({url:              "http://127.0.0.1:1234/#{token}/api/state",
                           exception_detail: "fetch http://127.0.0.1:1234/#{token}/?locus=chr1:1-20 failed"}), nil)
    output = IO::Memory.new
    D4Plot::Logging::TextFormatter.format(entry, output)
    output.to_s.should contain("[local-url-redacted]")
    output.to_s.should_not contain(token)
    output.to_s.should_not contain("chr1:1-20")
  end

  it "bounds queued logs without yielding the caller and drains them on close" do
    dispatcher = D4Plot::Logging::NonBlockingDispatcher.new(2)
    entered = Channel(Nil).new(1)
    gate = LogGate.new
    backend = SlowLogBackend.new(dispatcher, entered, gate)
    builder = Log::Builder.new
    Log.setup(:debug, backend, builder: builder)
    logger = builder.for("d4_plot.test")
    begin
      logger.info { "first" }
      select
      when entered.receive
      when timeout(5.seconds)
        raise "Logger did not start"
      end
      owner = Thread.current
      16.times { logger.info { "queued" } }
      Thread.current.should be(owner)
      gate.release
      backend.close
      backend.entries.count { |entry| entry.message == "queued" }.should eq(2)
      dropped = backend.entries.find! { |entry| entry.message == "log.entries_dropped" }
      dropped.data[:count].should eq(Log::Metadata::Value.new(14))
    ensure
      gate.release
      backend.close
    end
  end

  it "waits for an active log write before closing" do
    dispatcher = D4Plot::Logging::NonBlockingDispatcher.new
    entered = Channel(Nil).new(1)
    gate = LogGate.new
    backend = SlowLogBackend.new(dispatcher, entered, gate)
    builder = Log::Builder.new
    Log.setup(:info, backend, builder: builder)
    builder.for("d4_plot.test").info { "pending write" }
    select
    when entered.receive
    when timeout(5.seconds)
      raise "Logger did not start"
    end

    releaser = Fiber::ExecutionContext::Isolated.new("log-close-release") do
      sleep 20.milliseconds
      gate.release
    end
    backend.close
    releaser.wait
    backend.entries.map(&.message).should eq(["pending write"])
  ensure
    gate.try(&.release)
    backend.try(&.close)
  end

  it "keeps application work running when log writes fail" do
    dispatcher = D4Plot::Logging::NonBlockingDispatcher.new
    backend = Log::IOBackend.new(BrokenLogIO.new, dispatcher: dispatcher)
    builder = Log::Builder.new
    Log.setup(:info, backend, builder: builder)
    builder.for("d4_plot.test").info { "write fails" }
    backend.close
    builder.for("d4_plot.test").info { "closed logger" }
    backend.close
  end

  it "serializes concurrent writers and concurrent close calls" do
    dispatcher = D4Plot::Logging::NonBlockingDispatcher.new(4096)
    backend = CollectingLogBackend.new(dispatcher)
    builder = Log::Builder.new
    Log.setup(:info, backend, builder: builder)
    logger = builder.for("d4_plot.test")

    writers = 4.times.map do |writer|
      Fiber::ExecutionContext::Isolated.new("log-writer-#{writer}") do
        500.times { |index| logger.info &.emit("parallel.entry", writer: writer, index: index) }
      end
    end
    writers.each(&.wait)

    closers = 2.times.map do |index|
      Fiber::ExecutionContext::Isolated.new("log-closer-#{index}") { backend.close }
    end
    closers.each(&.wait)

    backend.entries.size.should eq(2_000)
    4.times do |writer|
      indexes = backend.entries.select { |entry| entry.data[:writer]? == writer }.map(&.data[:index].to_s.to_i)
      indexes.should eq((0...500).to_a)
    end
  ensure
    backend.try(&.close)
  end

  it "retains two rotated files and the latest complete entry" do
    path = File.tempname("d4-log-rotation", ".log")
    backend = D4Plot::Logging::RotatingFileBackend.new(path, Log::DirectDispatcher, max_bytes: 1)
    builder = Log::Builder.new
    Log.setup(:info, backend, builder: builder)
    logger = builder.for("d4_plot.test")
    4.times { |index| logger.info { "entry.#{index}" } }
    backend.close
    File.read(path).should contain("entry.3")
    File.read("#{path}.1").should contain("entry.2")
    File.read("#{path}.2").should contain("entry.1")
    File.exists?("#{path}.3").should be_false
  ensure
    backend.try(&.close)
    if path
      [path, "#{path}.1", "#{path}.2"].each { |file| File.delete(file) if File.exists?(file) }
    end
  end

  it "configures and closes across OS threads without a second close at exit" do
    path = File.tempname("d4-log-lifecycle", ".log")
    previous_path = ENV["D4_PLOT_LOG_FILE"]?
    previous_level = ENV["LOG_LEVEL"]?
    ENV["D4_PLOT_LOG_FILE"] = path
    ENV["LOG_LEVEL"] = "INFO"

    setup_context = Fiber::ExecutionContext::Isolated.new("log-setup-test") do
      D4Plot::Logging.setup
    end
    setup_context.wait
    D4Plot::Log.info { "lifecycle.probe" }
    D4Plot::Logging.close
    D4Plot::Logging.close

    output = File.read(path)
    output.should contain("app.started")
    output.should contain("lifecycle.probe")
    output.should contain("app.stopped")
    D4Plot::Log.backend.should be_nil
  ensure
    D4Plot::Logging.close
    if previous_path
      ENV["D4_PLOT_LOG_FILE"] = previous_path
    else
      ENV.delete("D4_PLOT_LOG_FILE")
    end
    if previous_level
      ENV["LOG_LEVEL"] = previous_level
    else
      ENV.delete("LOG_LEVEL")
    end
    File.delete(path) if path && File.exists?(path)
    Log.setup(:none)
  end

  it "records file failures before converting exceptions to UI strings" do
    Log.capture("d4_plot.file_loader") do |logs|
      loader = D4Plot::FileLoader.new(->(path : String, _cancelled : Proc(Bool)) {
        raise IO::Error.new("unreadable source") if path == "private.d4"
        [] of D4Plot::TrackSource
      })
      id = loader.submit(["private.d4"])
      deadline = Time.instant + 5.seconds
      until loader.poll
        raise "File loader did not finish" if Time.instant >= deadline
        sleep 1.millisecond
      end
      loader.close
      loader.wait
      logs.check(:error, "files.failed")
      logs.entry.data[:request_id].should eq(Log::Metadata::Value.new(id))
      logs.check(:debug, "files.failed.detail")
      logs.entry.exception.should be_nil
      logs.entry.data[:exception_detail].to_s.should contain("unreadable source")
    ensure
      loader.try(&.close)
      loader.try(&.wait)
    end
  end

  it "distinguishes cancelled file reads from successful replacements" do
    Log.capture("d4_plot.file_loader") do |logs|
      entered = Channel(Nil).new(1)
      gate = LogGate.new
      loader = D4Plot::FileLoader.new(->(path : String, _cancelled : Proc(Bool)) {
        if path == "slow.d4"
          entered.send(nil)
          gate.wait
        end
        [] of D4Plot::TrackSource
      })
      first = loader.submit(["slow.d4"])
      select
      when entered.receive
      when timeout(5.seconds)
        raise "File loader did not start"
      end
      loader.cancel
      second = loader.submit(["replacement.d4"])
      gate.release
      deadline = Time.instant + 5.seconds
      until loader.poll
        raise "File loader did not finish" if Time.instant >= deadline
        sleep 1.millisecond
      end
      loader.close
      loader.wait
      logs.check(:debug, "files.cancelled")
      logs.entry.data[:request_id].should eq(Log::Metadata::Value.new(first))
      logs.check(:info, "files.completed")
      logs.entry.data[:request_id].should eq(Log::Metadata::Value.new(second))
      logs.empty
    ensure
      gate.try(&.release)
      loader.try(&.close)
      loader.try(&.wait)
    end
  end

  it "records a conversion failure with a job ID" do
    Log.capture("d4_plot.conversion") do |logs|
      worker = D4Plot::ConversionWorker.new
      worker.start(D4Plot::ConversionRequest.new("missing-input.bam", "unused-output.d4"))
      worker.wait
      logs.check(:info, "conversion.started")
      id = logs.entry.data[:job_id]
      logs.check(:error, "conversion.failed")
      logs.entry.data[:job_id].should eq(id)
      logs.check(:info, "conversion.finished")
      logs.entry.data[:state].should eq(Log::Metadata::Value.new("failed"))
    end
  end

  it "correlates HTTP responses with logs without logging the token" do
    dispatcher = D4Plot::Logging::NonBlockingDispatcher.new
    output = IO::Memory.new
    backend = Log::IOBackend.new(output, formatter: D4Plot::Logging::TextFormatter, dispatcher: dispatcher)
    Log.builder.bind("d4_plot.web", :debug, backend)
    server = D4Plot::IGVWebServer.new([] of D4Plot::TrackSource)
    server.start
    response = HTTP::Client.get("#{server.url}api/state")
    response.status_code.should eq(200)
    request_id = response.headers["X-Request-ID"]
    server.close
    server.wait
    backend.close
    output.to_s.should contain("http.completed")
    output.to_s.should contain("request_id: #{request_id.inspect}")
    output.to_s.should_not contain(URI.parse(server.url).path.split('/')[1])
  ensure
    server.try(&.close)
    server.try(&.wait)
    backend.try(&.close)
    Log.builder.unbind("d4_plot.web", :debug, backend) if backend
  end
end
