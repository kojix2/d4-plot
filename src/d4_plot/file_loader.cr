require "./track_layer"
require "./log"

module D4Plot
  class FileLoadRequest
    getter id : Int32
    getter paths : Array(String)
    getter existing : Array(TrackSource)

    def initialize(@id : Int32, @paths : Array(String), @existing : Array(TrackSource)); end

    def_equals_and_hash id, paths, existing
  end

  class FileLoadProgress
    getter id : Int32
    getter current : Int32
    getter total : Int32
    getter path : String

    def initialize(
      @id : Int32,
      @current : Int32,
      @total : Int32,
      @path : String,
    )
    end

    def_equals_and_hash id, current, total, path
  end

  class FileLoadResult
    getter id : Int32
    getter sources : Array(TrackSource)
    getter error : String?

    def initialize(@id : Int32, @sources : Array(TrackSource), @error : String? = nil); end

    def_equals_and_hash id, sources, error
  end

  # Metadata reads use their own handles and never call the native UI. A new
  # request or cancellation invalidates both queued and in-flight results.
  class FileLoader
    Log = D4Plot::Log.for("file_loader")
    @mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @generation = Atomic(Int32).new(0)
    @pending : FileLoadRequest?
    @progress : FileLoadProgress?
    @result : FileLoadResult?
    @closed = false
    @worker : Fiber::ExecutionContext::Isolated

    def initialize(@read_sources : Proc(String, Proc(Bool), Array(TrackSource)) = ->(path : String, cancelled : Proc(Bool)) { TrackSource.load(path, cancelled) })
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-file-reader") { work }
    end

    def submit(paths : Array(String), existing = [] of TrackSource) : Int32
      id = @generation.add(1) + 1
      @mutex.synchronize do
        raise D4Plot.t("errors.viewer_closed") if @closed
        @pending = FileLoadRequest.new(id, paths.dup, existing.dup)
        @progress = nil
        @result = nil
        @wake.signal
      end
      id
    end

    def progress : FileLoadProgress?
      @mutex.synchronize { @progress }
    end

    def poll : FileLoadResult?
      @mutex.synchronize do
        result = @result
        @result = nil
        result
      end
    end

    def cancel : Nil
      @generation.add(1)
      @mutex.synchronize do
        @pending = nil
        @progress = nil
        @result = nil
      end
    end

    def close : Nil
      cancel
      @mutex.synchronize do
        @closed = true
        @wake.signal
      end
    end

    def wait : Nil
      @worker.wait
    end

    private def next_request : FileLoadRequest?
      @mutex.synchronize do
        while !@closed && @pending.nil?
          @wake.wait(@mutex)
        end
        return if @closed
        request = @pending
        @pending = nil
        request
      end
    end

    private def work : Nil
      while request = next_request
        started = Time.instant
        Log.info &.emit("files.started", request_id: request.id, files: request.paths.size, existing_tracks: request.existing.size)
        sources = [] of TrackSource
        keys = Set(Tuple(String, String)).new
        request.existing.each do |source|
          sources << source if keys.add?(source.key)
        end
        path = ""
        begin
          request.paths.each_with_index do |file, index|
            break unless request.id == @generation.get
            path = file
            Log.debug &.emit("file.opening", request_id: request.id, file_index: index, path: path)
            @mutex.synchronize do
              @progress = FileLoadProgress.new(request.id, index + 1, request.paths.size, path) if request.id == @generation.get
            end
            cancelled = -> { request.id != @generation.get }
            loaded = @read_sources.call(path, cancelled)
            break unless request.id == @generation.get
            loaded.each do |source|
              sources << source if keys.add?(source.key)
            end
            # Include the offending file in reference-compatibility errors.
            TrackSource.chromosomes(sources)
          end
          result = FileLoadResult.new(request.id, sources)
        rescue ex
          Logging.report_exception(Log, "files.failed", ex, request_id: request.id, elapsed_ms: Logging.elapsed_ms(started)) if request.id == @generation.get
          result = FileLoadResult.new(request.id, [] of TrackSource, "#{path}\n#{ex.message || ex.class.name}")
        end
        finish(request, result, started)
      end
    end

    private def finish(request, result, started) : Nil
      if request.id != @generation.get
        Log.debug &.emit("files.cancelled", request_id: request.id, elapsed_ms: Logging.elapsed_ms(started))
      elsif result.error.nil?
        Log.info &.emit("files.completed", request_id: request.id, tracks: result.sources.size, elapsed_ms: Logging.elapsed_ms(started))
      end
      @mutex.synchronize do
        if !@closed && request.id == @generation.get
          @result = result
          @progress = nil
        end
      end
    end
  end
end
