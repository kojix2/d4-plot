require "./track_layer"
require "./annotation"

module D4Plot
  class ViewRequest
    getter id : Int32
    getter sources : Array(TrackSource)
    getter region : Region
    getter bins : Int32
    getter use_index : Bool
    getter annotation_path : String?
    getter annotation_limit : Int32
    getter annotation_fallback : String?

    def initialize(
      @id : Int32,
      @sources : Array(TrackSource),
      @region : Region,
      @bins : Int32,
      @use_index : Bool,
      @annotation_path : String?,
      @annotation_limit : Int32,
      @annotation_fallback : String? = nil
    )
    end

    def_equals_and_hash id, sources, region, bins, use_index, annotation_path, annotation_limit, annotation_fallback
  end

  class ViewResult
    getter request : ViewRequest
    getter layers : Array(LayerSample)
    getter annotation_track : AnnotationTrack?
    getter elapsed_ms : Float64
    getter error : String?
    getter annotation_error : String?

    def initialize(
      @request : ViewRequest,
      @layers : Array(LayerSample),
      @annotation_track : AnnotationTrack?,
      @elapsed_ms : Float64,
      @error : String?,
      @annotation_error : String? = nil
    )
    end

    def_equals_and_hash request, layers, annotation_track, elapsed_ms, error, annotation_error
  end

  # Reusing a descriptor solely by pathname makes an atomic replacement of a
  # D4 or annotation file invisible to the viewer. Keep both the file
  # identity and the observable contents stamp so a same-path replacement
  # reopens/reloads it on the next request.
  private class ViewFileStamp
    getter size : Int64
    getter modified_ns : Int128
    getter identity : File::Info

    def initialize(@identity : File::Info)
      @size = @identity.size
      @modified_ns = @identity.modification_time.to_unix_ns
    end

    def_equals_and_hash size, modified_ns, identity

    def same_source?(other : ViewFileStamp) : Bool
      @identity.same_file?(other.identity) && @size == other.size && @modified_ns == other.modified_ns
    end
  end

  # One worker owns its file handles. Only the latest pending request/result is
  # retained, so rapid navigation cannot accumulate work or large allocations.
  class ViewLoader
    Log = D4Plot::Log.for("view_loader")
    # Native synchronization avoids yielding the GUI fiber into Crystal's
    # scheduler while libui owns the main thread's event loop.
    @mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @pending : ViewRequest?
    @result : ViewResult?
    @closed = false
    @generation = Atomic(Int32).new(0)
    @worker : Fiber::ExecutionContext::Isolated
    @file : D4::File?
    @file_path : String?
    @file_stamp : ViewFileStamp?
    @annotation_index : AnnotationIndex?
    @annotation_stamp : ViewFileStamp?

    def initialize
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-reader") { work }
    end

    def submit(sources : Array(TrackSource), region, bins, use_index, annotation_path, annotation_limit, annotation_fallback : String? = nil) : Int32
      id = @generation.add(1) + 1
      @mutex.synchronize do
        raise D4Plot.t("errors.viewer_closed") if @closed
        @pending = ViewRequest.new(id, sources.dup, region, bins, use_index, annotation_path, annotation_limit, annotation_fallback)
        @wake.signal
      end
      id
    end

    def poll : ViewResult?
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
        @result = nil
      end
    end

    def close : Nil
      @generation.add(1)
      @mutex.synchronize do
        @closed = true
        @pending = nil
        @wake.signal
      end
    end

    def wait : Nil
      @worker.wait
    end

    private def work : Nil
      while request = next_request
        next unless request.id == @generation.get
        started = Time.instant
        Log.debug &.emit("view.started", request_id: request.id, tracks: request.sources.size,
          region: request.region.to_s, bins: request.bins, use_index: request.use_index)
        begin
          cancelled = -> { request.id != @generation.get }
          layers = request.sources.map do |source|
            raise SamplingCancelled.new if cancelled.call
            sample(source, request, cancelled)
          end
          raise SamplingCancelled.new if cancelled.call
          track, annotation_error = annotation_for(request, cancelled)
          result = ViewResult.new(request, layers, track, (Time.instant - started).total_milliseconds, nil, annotation_error)
        rescue SamplingCancelled | AnnotationCancelled
          Log.debug &.emit("view.cancelled", request_id: request.id, elapsed_ms: Logging.elapsed_ms(started))
          next
        rescue ex
          Logging.report_exception(Log, "view.failed", ex, request_id: request.id, elapsed_ms: Logging.elapsed_ms(started))
          result = ViewResult.new(request, [] of LayerSample, nil, (Time.instant - started).total_milliseconds, ex.message || ex.class.name)
        end
        unless request.id == @generation.get
          Log.debug &.emit("view.discarded", request_id: request.id)
          next
        end
        Log.info &.emit("view.completed", request_id: request.id, tracks: result.layers.size,
          failed_tracks: result.layers.count { |layer| !layer.error.nil? }, annotation_failed: !result.annotation_error.nil?,
          failed: !result.error.nil?, elapsed_ms: result.elapsed_ms.round(2))
        @mutex.synchronize do
          @result = result unless @closed || request.id != @generation.get
        end
      end
    ensure
      @file.try(&.close)
    end

    private def sample(source, request, cancelled) : LayerSample
      unless source.chromosomes.has_key?(request.region.chromosome)
        Log.debug &.emit("track.no_data", request_id: request.id, path: source.path, track: source.name, chromosome: request.region.chromosome)
        return LayerSample.new(source, nil, D4Plot.t("errors.no_track_data", chromosome: request.region.chromosome))
      end
      request.region.validate!(source.chromosomes)
      current_file = file_for(source.path)
      points = ::Log.with_context(request_id: request.id) do
        DataSampler.downsample(current_file.track(source.name), request.region, request.bins, request.use_index, cancelled)
      end
      LayerSample.new(source, SampledView.new(request.region, points), nil)
    rescue ex : SamplingCancelled
      raise ex
    rescue ex
      Logging.report_exception(Log, "track.failed", ex, request_id: request.id)
      Log.debug &.emit("track.failed.source", request_id: request.id, path: source.path, track: source.name)
      LayerSample.new(source, nil, D4Plot.t("errors.read_failed", error: ex.message || ex.class.name))
    end

    private def next_request : ViewRequest?
      @mutex.synchronize do
        while @pending.nil? && !@closed
          @wake.wait(@mutex)
        end
        request = @pending
        @pending = nil
        request
      end
    end

    private def file_for(path : String) : D4::File
      stamp = file_stamp(path)
      if file = @file
        if @file_path == path && (previous = @file_stamp) && previous.same_source?(stamp)
          return file
        end
      end
      opened = D4.open(path)
      @file.try(&.close)
      @file = opened
      @file_path = path
      @file_stamp = stamp
      opened
    end

    private def annotation_for(request : ViewRequest, cancelled : Proc(Bool)) : Tuple(AnnotationTrack?, String?)
      unless path = request.annotation_path
        @annotation_index = nil
        @annotation_stamp = nil
        return {nil, nil}
      end
      {read_annotation(path, request, cancelled), nil}
    rescue ex : AnnotationCancelled
      raise ex
    rescue ex
      Logging.report_exception(Log, "annotation.failed", ex, request_id: request.id)
      error = ex.message || ex.class.name
      # A rejected replacement must not discard the previous selection, and its
      # fallback must be read at the new coordinates, not reuse an old track.
      track = if fallback = request.annotation_fallback
                begin
                  read_annotation(fallback, request, cancelled)
                rescue ex : AnnotationCancelled
                  raise ex
                rescue exception
                  Logging.report_exception(Log, "annotation.fallback_failed", exception, request_id: request.id)
                  AnnotationTrack.notice(D4Plot.t("annotation.unavailable"))
                end
              end
      {track, error}
    end

    private def read_annotation(path, request, cancelled)
      stamp = file_stamp(path)
      index = @annotation_index
      if index && index.path == path && (previous = @annotation_stamp) && previous.same_source?(stamp)
        return index.track_for(request.region, 5_000_000_u32, request.annotation_limit)
      end

      index = AnnotationIndex.load(path, cancelled)
      @annotation_index = index
      @annotation_stamp = stamp
      index.track_for(request.region, 5_000_000_u32, request.annotation_limit)
    end

    private def file_stamp(path : String) : ViewFileStamp
      ViewFileStamp.new(File.info(path))
    end
  end
end
