require "d4"
require "./data_sampler"
require "./track_layer"

module D4Plot
  class SignalQueryBusy < Exception
  end

  class SignalQueryCancelled < Exception
  end

  class SignalQueryClosed < Exception
  end

  # Fixed-grid layout for a browser viewport.  Its left edge is anchored at
  # chromosome coordinate zero, so adjacent requests can reuse the same bins.
  # The final bin is clipped to the chromosome length.
  class BinLayout
    getter bins : Array(BinRange)
    getter width : Int64

    def initialize(@bins : Array(BinRange), @width : Int64)
      raise ArgumentError.new("A bin layout needs at least one bin") if @bins.empty?
      raise ArgumentError.new("Invalid bin width") if @width <= 0
    end

    # Bound checks are deliberately explicit because browser coordinates are
    # untrusted and may be near Int64 limits.
    # ameba:disable Metrics/CyclomaticComplexity
    def self.for_viewport(start0 : Int64, end0 : Int64, bp_per_pixel : Float64, chromosome_size : Int64,
                          max_bins : Int32 = 8_192, alignment : Int64? = nil) : self
      raise ArgumentError.new("Invalid chromosome size") if chromosome_size <= 0
      raise ArgumentError.new("Invalid viewport interval") if start0 < 0 || end0 <= start0 || end0 > chromosome_size
      raise ArgumentError.new("Invalid bp per pixel") unless bp_per_pixel.finite? && bp_per_pixel > 0.0
      raise ArgumentError.new("Invalid bin limit") if max_bins <= 0

      range = end0 - start0
      # Avoid converting an otherwise finite but enormous browser value to an
      # Int64.  Any bp-per-pixel value at least as wide as the request means
      # one bin is sufficient.
      requested_width = bp_per_pixel >= range.to_f64 ? range : bp_per_pixel.ceil.to_i64
      # Alignment can add at most one bin.  This width guarantees the complete
      # fixed grid stays within max_bins without trial-and-error growth.
      capped_width = if max_bins == 1
                       range
                     else
                       (range + max_bins - 2) // (max_bins - 1)
                     end
      width = Math.max(1_i64, Math.max(requested_width, capped_width))
      if alignment
        raise ArgumentError.new("Invalid bin alignment") if alignment <= 0
        remainder = width % alignment
        width += alignment - remainder unless remainder == 0
      end
      aligned_start = start0 // width * width
      aligned_end = ((end0 - 1) // width + 1) * width
      aligned_end = Math.min(aligned_end, chromosome_size)

      bins = [] of BinRange
      cursor = aligned_start
      while cursor < aligned_end
        right = Math.min(cursor + width, chromosome_size)
        bins << BinRange.new(cursor, right)
        cursor = right
      end
      raise ArgumentError.new("Viewport produces too many bins") if bins.size > max_bins
      new(bins, width)
    end
  end

  record SignalResult, bins : Array(SampledBin), bin_width : Int64, cache_hit : Bool, exact : Bool do
    def duplicate(cache_hit : Bool = self.cache_hit) : SignalResult
      SignalResult.new(bins.dup, bin_width, cache_hit, exact)
    end
  end

  # Keep the stat identity as well as the values used in cache keys.  A D4
  # file can be atomically replaced with another file that happens to have
  # the same size and timestamp; in that case size/mtime alone would retain
  # an old file descriptor and cached bins for the new pathname.
  private struct SignalFileStamp
    getter size : Int64
    getter modified_ns : Int128
    getter identity : File::Info

    def initialize(@identity : File::Info)
      @size = @identity.size
      @modified_ns = @identity.modification_time.to_unix_ns
    end

    def same_source?(other : SignalFileStamp) : Bool
      @identity.same_file?(other.identity) && @size == other.size && @modified_ns == other.modified_ns
    end
  end

  private record SignalClientNavigation, navigation : Int64, last_seen : Time::Instant

  private class SignalCacheEntry
    property last_used : Int64

    def initialize(@path : String, @stamp : SignalFileStamp, @bins : Array(SampledBin), @bin_width : Int64,
                   @exact : Bool, @bytes : Int64, @last_used : Int64); end

    getter path : String
    getter stamp : SignalFileStamp
    getter bins : Array(SampledBin)
    getter bin_width : Int64
    getter? exact : Bool
    getter bytes : Int64
  end

  private class SignalFileHandle
    property last_used : Int64

    def initialize(@file : D4::File, @stamp : SignalFileStamp, @last_used : Int64); end

    getter file : D4::File
    getter stamp : SignalFileStamp
  end

  private class SignalQueryCompletion
    def initialize(@result : SignalResult? = nil, @error : Exception? = nil); end

    getter result : SignalResult?
    getter error : Exception?
  end

  private class SignalQueryRequest
    getter reply : Channel(SignalQueryCompletion)

    def initialize(@source : TrackSource, @d4_chromosome : String, @layout : BinLayout,
                   @reference_revision : String, @client_id : String, @navigation_id : Int64,
                   @reply : Channel(SignalQueryCompletion), @request_id : Int64); end

    getter request_id : Int64

    getter source : TrackSource
    getter d4_chromosome : String
    getter layout : BinLayout
    getter reference_revision : String
    getter client_id : String
    getter navigation_id : Int64
  end

  # A bounded, single-reader D4 query service.  The worker owns all D4 file
  # handles; GUI readers and HTTP readers consequently never share a mutable
  # seekable source.  One worker is intentional as the safe default for HDDs,
  # NFS, and large compressed containers.
  class SignalQuery
    Log                    = D4Plot::Log.for("signal_query")
    DEFAULT_MAX_PENDING    = 32
    DEFAULT_MAX_OPEN_FILES =  8
    DEFAULT_CACHE_BYTES    = 64_i64 * 1024 * 1024
    MAX_CLIENT_NAVIGATIONS = 2_048
    CLIENT_NAVIGATION_TTL  = 10.minutes

    @queue : Channel(SignalQueryRequest)
    @worker : Fiber::ExecutionContext::Isolated
    @closed = Atomic(Bool).new(false)
    @navigation_mutex = Thread::Mutex.new
    @latest_navigation = {} of String => SignalClientNavigation
    @revision_mutex = Thread::Mutex.new
    @active_revision = nil.as(String?)
    @files = {} of String => SignalFileHandle
    @cache = {} of String => SignalCacheEntry
    @clock = 0_i64
    @cache_bytes = 0_i64

    def initialize(@max_open_files : Int32 = DEFAULT_MAX_OPEN_FILES, @max_cache_bytes : Int64 = DEFAULT_CACHE_BYTES,
                   max_pending : Int32 = DEFAULT_MAX_PENDING)
      raise ArgumentError.new("Invalid open-file limit") if @max_open_files <= 0
      raise ArgumentError.new("Invalid cache limit") if @max_cache_bytes < 0
      raise ArgumentError.new("Invalid pending-query limit") if max_pending <= 0
      @queue = Channel(SignalQueryRequest).new(max_pending)
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-signal-reader") { work }
    end

    def query(source : TrackSource, d4_chromosome : String, layout : BinLayout, reference_revision : String,
              client_id : String, navigation_id : Int64, request_id : Int64 = Logging.next_correlation_id) : SignalResult
      raise SignalQueryClosed.new("D4 reader is closed") if @closed.get
      validate_request!(source, d4_chromosome, layout, reference_revision, client_id, navigation_id)
      note_navigation(navigation_key(source, client_id), navigation_id)
      reply = Channel(SignalQueryCompletion).new(1)
      request = SignalQueryRequest.new(source, d4_chromosome, layout, reference_revision, client_id, navigation_id, reply, request_id)
      begin
        select
        when @queue.send(request)
        else
          raise SignalQueryBusy.new("D4 reader queue is full; retry shortly")
        end
      rescue Channel::ClosedError
        raise SignalQueryClosed.new("D4 reader is closed")
      end
      completion = reply.receive
      if error = completion.error
        raise error
      end
      completion.result || raise SignalQueryClosed.new("D4 query completed without a result")
    rescue Channel::ClosedError
      raise SignalQueryClosed.new("D4 reader is closed")
    end

    def close : Nil
      return if @closed.get
      @closed.set(true)
      @queue.close
    end

    # A web session replacement invalidates both queued and active reads from
    # its prior immutable snapshot. Standalone users can omit this call; in
    # that mode every caller-supplied revision remains valid.
    def activate_revision(revision : String) : Nil
      raise ArgumentError.new("Invalid reference revision") if revision.empty? || revision.bytesize > 256
      @revision_mutex.synchronize { @active_revision = revision }
    end

    def wait : Nil
      @worker.wait
    end

    private def work : Nil
      while request = @queue.receive?
        completion = begin
          if stale?(request)
            SignalQueryCompletion.new(error: SignalQueryCancelled.new("D4 query was superseded"))
          else
            SignalQueryCompletion.new(result: execute(request))
          end
        rescue ex
          SignalQueryCompletion.new(error: ex)
        end
        request.reply.send(completion)
      end
    ensure
      @files.each_value(&.file.close)
      @files.clear
    end

    private def execute(request : SignalQueryRequest) : SignalResult
      started = Time.instant
      Log.debug &.emit("query.started", request_id: request.request_id, navigation_id: request.navigation_id,
        revision: request.reference_revision, bins: request.layout.bins.size)
      raise SignalQueryCancelled.new("D4 query was superseded") if stale?(request)
      stamp = file_stamp(request.source.path)
      track = file_for(request.source.path, stamp).track(request.source.name)
      layout = index_aligned_layout(request.layout, track, request.source.chromosomes[request.d4_chromosome].to_i64)
      key = cache_key(request, stamp, layout)
      if entry = @cache[key]?
        if entry.stamp.same_source?(stamp)
          entry.last_used = tick
          raise SignalQueryCancelled.new("D4 query was superseded") if stale?(request)
          Log.debug &.emit("query.completed", request_id: request.request_id, cache_hit: true,
            exact: entry.exact?, bins: entry.bins.size, elapsed_ms: Logging.elapsed_ms(started))
          return SignalResult.new(entry.bins.dup, entry.bin_width, true, entry.exact?)
        end
        # The handle may have been evicted before an atomic same-size,
        # same-timestamp replacement. In that case file_for cannot observe
        # the old identity, so invalidate the path's result cache here.
        discard_cached_path(request.source.path)
      end

      cancelled = -> { stale?(request) }
      sampled = ::Log.with_context(request_id: request.request_id) do
        DataSampler.display_bins(track, request.d4_chromosome, layout.bins, cancelled)
      end
      raise SignalQueryCancelled.new("D4 query was superseded") if stale?(request)
      cache_result(key, request.source.path, stamp, sampled.bins, layout.width, sampled.exact)
      Log.debug &.emit("query.completed", request_id: request.request_id, cache_hit: false,
        exact: sampled.exact, bins: sampled.bins.size, elapsed_ms: Logging.elapsed_ms(started))
      SignalResult.new(sampled.bins.dup, layout.width, false, sampled.exact)
    rescue ex : SamplingCancelled
      raise SignalQueryCancelled.new(ex.message || "D4 query was superseded")
    end

    private def file_for(path : String, stamp : SignalFileStamp) : D4::File
      if entry = @files[path]?
        if entry.stamp.same_source?(stamp)
          entry.last_used = tick
          return entry.file
        end
        entry.file.close
        @files.delete(path)
        discard_cached_path(path)
      end

      opened = D4.open(path)
      @files[path] = SignalFileHandle.new(opened, stamp, tick)
      evict_files
      opened
    end

    private def evict_files : Nil
      while @files.size > @max_open_files
        oldest_path = oldest_file_path || break
        if entry = @files.delete(oldest_path)
          entry.file.close
        end
      end
    end

    private def oldest_file_path : String?
      path = nil.as(String?)
      oldest = Int64::MAX
      @files.each do |candidate_path, entry|
        if entry.last_used < oldest
          path = candidate_path
          oldest = entry.last_used
        end
      end
      path
    end

    private def cache_result(key : String, path : String, stamp : SignalFileStamp, bins : Array(SampledBin),
                             bin_width : Int64, exact : Bool) : Nil
      return if @max_cache_bytes == 0
      bytes = bins.size.to_i64 * 24
      return if bytes > @max_cache_bytes
      if previous = @cache[key]?
        @cache_bytes -= previous.bytes
      end
      @cache[key] = SignalCacheEntry.new(path, stamp, bins.dup, bin_width, exact, bytes, tick)
      @cache_bytes += bytes
      evict_cache
    end

    private def evict_cache : Nil
      while @cache_bytes > @max_cache_bytes
        key = oldest_cache_key || break
        if entry = @cache.delete(key)
          @cache_bytes -= entry.bytes
        end
      end
    end

    private def oldest_cache_key : String?
      key = nil.as(String?)
      oldest = Int64::MAX
      @cache.each do |candidate_key, entry|
        if entry.last_used < oldest
          key = candidate_key
          oldest = entry.last_used
        end
      end
      key
    end

    private def discard_cached_path(path : String) : Nil
      doomed = @cache.select { |_key, entry| entry.path == path }.keys
      doomed.each do |key|
        if entry = @cache.delete(key)
          @cache_bytes -= entry.bytes
        end
      end
    end

    private def cache_key(request : SignalQueryRequest, stamp : SignalFileStamp, layout : BinLayout) : String
      first = layout.bins.first
      last = layout.bins.last
      String.build do |io|
        io << request.source.path << '\0' << stamp.size << '\0' << stamp.modified_ns << '\0'
        io << request.source.name << '\0' << request.d4_chromosome << '\0'
        io << first.start0 << '\0' << last.end0 << '\0' << layout.width << '\0' << layout.bins.size
      end
    end

    private def index_aligned_layout(layout : BinLayout, track : D4::Track, chromosome_size : Int64) : BinLayout
      {% if D4::Track.has_method?(:sum_index_granularity) %}
        return layout unless track.has_index?(D4::IndexKind::Sum)
        return layout unless granularity = track.sum_index_granularity
        return layout if layout.width < granularity || layout.width % granularity == 0
        BinLayout.for_viewport(layout.bins.first.start0, layout.bins.last.end0, layout.width.to_f64,
          chromosome_size, alignment: granularity)
      {% else %}
        layout
      {% end %}
    end

    private def file_stamp(path : String) : SignalFileStamp
      SignalFileStamp.new(File.info(path))
    end

    private def tick : Int64
      @clock += 1
    end

    private def note_navigation(client_id : String, navigation_id : Int64) : Nil
      @navigation_mutex.synchronize do
        now = Time.instant
        prune_navigation(now)
        current = @latest_navigation[client_id]?
        latest = current ? Math.max(current.navigation, navigation_id) : navigation_id
        @latest_navigation[client_id] = SignalClientNavigation.new(latest, now)
        while @latest_navigation.size > MAX_CLIENT_NAVIGATIONS
          evict_oldest_navigation
        end
      end
    end

    private def stale?(request : SignalQueryRequest) : Bool
      return true if @closed.get
      stale_revision = @revision_mutex.synchronize do
        current = @active_revision
        !current.nil? && current != request.reference_revision
      end
      return true if stale_revision
      @navigation_mutex.synchronize do
        latest = @latest_navigation[navigation_key(request.source, request.client_id)]?
        latest ? request.navigation_id < latest.navigation : false
      end
    end

    # A browser identity is deliberately scoped to a source as well. This
    # prevents an API client reusing its id across two D4 tracks from making
    # those independent reads cancel one another.
    private def navigation_key(source : TrackSource, client_id : String) : String
      String.build do |io|
        io << source.path << '\0' << source.name << '\0' << client_id
      end
    end

    private def prune_navigation(now : Time::Instant) : Nil
      expired = @latest_navigation.select { |_client_id, state| now - state.last_seen > CLIENT_NAVIGATION_TTL }.keys
      expired.each { |client_id| @latest_navigation.delete(client_id) }
    end

    private def evict_oldest_navigation : Nil
      oldest_id = @latest_navigation.min_by? { |_client_id, state| state.last_seen }.try(&.[0])
      @latest_navigation.delete(oldest_id) if oldest_id
    end

    private def validate_request!(source : TrackSource, d4_chromosome : String, layout : BinLayout,
                                  reference_revision : String, client_id : String, navigation_id : Int64) : Nil
      raise ArgumentError.new("Invalid D4 chromosome") if d4_chromosome.empty? || d4_chromosome.bytesize > 512
      raise ArgumentError.new("Invalid reference revision") if reference_revision.empty? || reference_revision.bytesize > 256
      raise ArgumentError.new("Invalid client id") if client_id.empty? || client_id.bytesize > 128
      raise ArgumentError.new("Invalid navigation id") if navigation_id < 0
      size = source.chromosomes[d4_chromosome]? || raise ArgumentError.new("D4 chromosome is unavailable")
      raise ArgumentError.new("Query exceeds D4 chromosome") if layout.bins.last.end0 > size
    end
  end
end
