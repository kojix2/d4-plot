require "./track_layer"
require "./annotation"

module D4Plot
  record ViewRequest, id : Int32, sources : Array(TrackSource), region : Region,
    bins : Int32, use_index : Bool, annotation_path : String?, annotation_limit : Int32,
    annotation_fallback : String? = nil

  record ViewResult, request : ViewRequest, layers : Array(LayerSample), annotation_track : AnnotationTrack?,
    elapsed_ms : Float64, error : String?, annotation_error : String? = nil

  # One worker owns its file handles. Only the latest pending request/result is
  # retained, so rapid navigation cannot accumulate work or large allocations.
  class ViewLoader
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
    @annotation_index : AnnotationIndex?

    def initialize
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-reader") { work }
    end

    def submit(sources : Array(TrackSource), region, bins, use_index, annotation_path, annotation_limit, annotation_fallback : String? = nil) : Int32
      id = @generation.add(1) + 1
      @mutex.synchronize do
        raise "Viewer is closed" if @closed
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
        begin
          cancelled = -> { request.id != @generation.get }
          layers = request.sources.map do |source|
            raise SamplingCancelled.new if cancelled.call
            sample(source, request, cancelled)
          end
          raise SamplingCancelled.new if cancelled.call
          track, annotation_error = annotation_for(request)
          result = ViewResult.new(request, layers, track, (Time.instant - started).total_milliseconds, nil, annotation_error)
        rescue SamplingCancelled
          next
        rescue ex
          result = ViewResult.new(request, [] of LayerSample, nil, (Time.instant - started).total_milliseconds, ex.message || ex.class.name)
        end
        next unless request.id == @generation.get
        @mutex.synchronize do
          @result = result unless @closed || request.id != @generation.get
        end
      end
    ensure
      @file.try(&.close)
    end

    private def sample(source, request, cancelled) : LayerSample
      unless source.chromosomes.has_key?(request.region.chromosome)
        return LayerSample.new(source, nil, "No data for #{request.region.chromosome} in this track")
      end
      request.region.validate!(source.chromosomes)
      current_file = file_for(source.path)
      points = DataSampler.downsample(current_file.track(source.name), request.region, request.bins, request.use_index, cancelled)
      LayerSample.new(source, SampledView.new(request.region, points), nil)
    rescue ex : SamplingCancelled
      raise ex
    rescue ex
      LayerSample.new(source, nil, "Read failed: #{ex.message || ex.class.name}")
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
      if file = @file
        return file if @file_path == path
      end
      opened = D4.open(path)
      @file.try(&.close)
      @file = opened
      @file_path = path
      opened
    end

    private def annotation_for(request : ViewRequest) : Tuple(AnnotationTrack?, String?)
      unless path = request.annotation_path
        @annotation_index = nil
        return {nil, nil}
      end
      {read_annotation(path, request), nil}
    rescue ex
      error = ex.message || ex.class.name
      # A rejected replacement must not discard the previous selection, and its
      # fallback must be read at the new coordinates, not reuse an old track.
      track = if fallback = request.annotation_fallback
                begin
                  read_annotation(fallback, request)
                rescue
                  AnnotationTrack.notice("Annotations unavailable in this region")
                end
              end
      {track, error}
    end

    private def read_annotation(path, request)
      index = @annotation_index
      index = AnnotationIndex.load(path) unless index && index.path == path
      track = index.track_for(request.region, 5_000_000_u32, request.annotation_limit)
      @annotation_index = index
      track
    end
  end
end
