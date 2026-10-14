require "./track_layer"

module D4Plot
  record FileLoadRequest, id : Int32, paths : Array(String), existing : Array(TrackSource)
  record FileLoadProgress, id : Int32, current : Int32, total : Int32, path : String
  record FileLoadResult, id : Int32, sources : Array(TrackSource), error : String? = nil

  # Metadata reads use their own handles and never call the native UI. A new
  # request or cancellation invalidates both queued and in-flight results.
  class FileLoader
    @mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @generation = Atomic(Int32).new(0)
    @pending : FileLoadRequest?
    @progress : FileLoadProgress?
    @result : FileLoadResult?
    @closed = false
    @worker : Fiber::ExecutionContext::Isolated

    def initialize(@read_sources : Proc(String, Array(TrackSource)) = ->(path : String) { TrackSource.load(path) })
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
        return nil if @closed
        request = @pending
        @pending = nil
        request
      end
    end

    private def work : Nil
      while request = next_request
        sources = request.existing.dup
        keys = sources.map(&.key).to_set
        path = ""
        begin
          request.paths.each_with_index do |file, index|
            break unless request.id == @generation.get
            path = file
            @mutex.synchronize do
              @progress = FileLoadProgress.new(request.id, index + 1, request.paths.size, path) if request.id == @generation.get
            end
            loaded = @read_sources.call(path)
            break unless request.id == @generation.get
            loaded.each do |source|
              sources << source if keys.add?(source.key)
            end
            # Include the offending file in reference-compatibility errors.
            TrackSource.chromosomes(sources)
          end
          result = FileLoadResult.new(request.id, sources)
        rescue ex
          result = FileLoadResult.new(request.id, [] of TrackSource, "#{path}\n#{ex.message || ex.class.name}")
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
end
