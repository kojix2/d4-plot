require "http/server"
require "big"
require "json"
require "random/secure"
require "uri"
require "./igv_integration"
require "./range_file_handler"
require "./reference"
require "./signal_query"
require "./track_layer"

module D4Plot
  # An immutable, browser-visible track descriptor.  Its opaque id is stable
  # for the lifetime of one SessionSnapshot and never contains a filename.
  private class IGVWebTrack
    getter id : String
    getter source : TrackSource
    getter compatibility : ReferenceCompatibility

    def initialize(@id : String, @source : TrackSource, @compatibility : ReferenceCompatibility); end

    def d4_chromosome_for(reference_chromosome : String) : String?
      if name = @compatibility.track_name_for(reference_chromosome)
        return name
      end
      return unless @compatibility.unverified?

      # A preset without a locally supplied dictionary cannot prove lengths.
      # Keep that fact visible as Unverified, but permit the exact name and the
      # two universally conventional spellings when they identify one track
      # contig unambiguously.  Do not apply general prefix stripping.
      return reference_chromosome if @source.chromosomes.has_key?(reference_chromosome)
      candidates = unverified_candidates(reference_chromosome).select { |name| @source.chromosomes.has_key?(name) }.uniq
      candidates.size == 1 ? candidates.first : nil
    end

    private def unverified_candidates(name : String) : Array(String)
      result = [] of String
      if match = /\Achr([1-9][0-9]*|X|Y)\z/.match(name)
        result << match[1]
      elsif /\A(?:[1-9][0-9]*|X|Y)\z/.matches?(name)
        result << "chr#{name}"
      end
      case name
      when "MT", "M", "chrM", "chrMT"
        result.concat(["MT", "M", "chrM", "chrMT"])
        result.delete(name)
      end
      result
    end
  end

  private class IGVWebSession
    getter revision : String
    getter reference : ResolvedReference
    getter tracks : Array(IGVWebTrack)
    getter initial_region : Region
    getter igv_reference_config : String

    def initialize(@revision : String, @reference : ResolvedReference, @tracks : Array(IGVWebTrack),
                   @initial_region : Region, @igv_reference_config : String); end

    def track(id : String) : IGVWebTrack?
      @tracks.find { |track| track.id == id }
    end
  end

  private class IGVWebResourceInstallation
    getter routes : Hash(String, ReferenceResource)
    getter file_route_ids : Array(String)
    getter urls : Hash(String, String)

    def initialize(@routes : Hash(String, ReferenceResource), @file_route_ids : Array(String), @urls : Hash(String, String)); end
  end

  # Read-only loopback server used by the browser integration.  API routes are
  # capability URLs issued per server instance; no route accepts a local path.
  class IGVWebServer
    MAX_FEATURE_BINS             = 8_192
    MAX_CONTROL_BODY_BYTES       = 4 * 1024
    MAX_QUERY_VALUE_BYTES        = 512
    MAX_GENERATED_RESOURCE_BYTES = 8_i64 * 1024 * 1024

    HTML        = {{ read_file?("#{__DIR__}/../../assets/igv_viewer.html") }}
    SCRIPT      = {{ read_file?("#{__DIR__}/../../assets/igv_viewer.js") }}
    BUNDLED_IGV = {{ read_file?("#{__DIR__}/../../vendor/igv/igv.min.js") }}

    @mutex = Thread::Mutex.new
    @request_drained = Thread::ConditionVariable.new
    @active_requests = 0
    @worker : Fiber::ExecutionContext::Isolated?
    @closed = false
    @range_files = RangeFileHandler.new
    @resource_routes = {} of String => ReferenceResource
    @file_route_ids = [] of String
    @track_ids = {} of Tuple(String, String) => String
    @sources : Array(TrackSource)
    @initial_region : Region?
    @reference_options : Hash(String, ReferenceSpec)
    @selected_reference_key : String
    @selected_reference : ReferenceSpec
    @snapshot : IGVWebSession
    @signal_query : SignalQuery

    def initialize(sources : Array(TrackSource), initial_region : Region? = nil, port : Int32 = 0,
                   reference : ReferenceSpec? = nil)
      raise ArgumentError.new("At least one D4 track is required") if sources.empty?
      raise ArgumentError.new("Invalid web port") unless (0..65_535).includes?(port)
      @sources = sources.dup
      @initial_region = initial_region
      @reference_options = {} of String => ReferenceSpec
      @selected_reference_key = ""
      @selected_reference = ReferenceSpec.preset("hg38")
      @server = HTTP::Server.new { |context| handle(context) }
      @address = @server.bind_tcp("127.0.0.1", port)
      @token = Random::Secure.urlsafe_base64(32)
      @signal_query = SignalQuery.new
      snapshot = begin
        install_reference_options(@sources, reference)
        @selected_reference_key = reference ? "configured" : "contigs-only"
        @selected_reference = @reference_options[@selected_reference_key]
        reconcile_track_ids(@sources)
        build_snapshot(@sources, @initial_region, @selected_reference)
      rescue ex
        # Constructor failures otherwise strand a bound loopback socket and
        # the isolated D4 worker, neither of which the caller can reach.
        @signal_query.close
        @server.close
        @signal_query.wait
        raise ex
      end
      @snapshot = snapshot
      @signal_query.activate_revision(@snapshot.revision)
    end

    def url : String
      "http://127.0.0.1:#{@address.port}/#{@token}/"
    end

    def browser_url(region : Region? = nil) : String
      region ? "#{url}?#{URI::Params.encode({"locus" => region.to_s})}" : url
    end

    # Starts a dedicated server thread for the GUI path.  ServeCLI calls
    # #listen directly, so no GUI runtime is linked into its entry point.
    def start : Nil
      @mutex.synchronize do
        raise "Web server is closed" if @closed
        @worker ||= Fiber::ExecutionContext::Isolated.new("d4-plot-igv-web") { listen }
      end
      nil
    end

    def listen : Nil
      @server.listen
    rescue ex : IO::Error
      raise ex unless closed?
    end

    # A replacement creates a new immutable snapshot.  Requests from an older
    # browser tab must include its old revision and therefore receive 409
    # rather than being silently redirected to a different track position.
    def update(sources : Array(TrackSource), initial_region : Region? = nil) : Nil
      raise ArgumentError.new("At least one D4 track is required") if sources.empty?
      @mutex.synchronize do
        raise "Web server is closed" if @closed
        @sources = sources.dup
        @initial_region = initial_region
        reconcile_track_ids(@sources)
        refresh_contigs_option(@sources)
        @selected_reference = @reference_options[@selected_reference_key]
        next_snapshot = build_snapshot(@sources, @initial_region, @selected_reference)
        @signal_query.activate_revision(next_snapshot.revision)
        @snapshot = next_snapshot
      end
    end

    def close : Nil
      should_close = @mutex.synchronize do
        next false if @closed
        @closed = true
        @file_route_ids.each { |id| @range_files.unregister(id) }
        @file_route_ids.clear
        @resource_routes.clear
        true
      end
      return unless should_close
      @signal_query.close
      @server.close
    end

    # Call this only after native UI teardown.  It waits for both owned worker
    # threads, allowing accepted reads to observe cancellation and close their
    # D4 handles before application shutdown completes.
    def wait : Nil
      @worker.try(&.wait)
      @mutex.synchronize do
        while @active_requests > 0
          @request_drained.wait(@mutex)
        end
      end
      @signal_query.wait
    end

    private def handle(context : HTTP::Server::Context) : Nil
      unless begin_request
        secure_headers(context.response)
        failure(context, 503, "SERVER_STOPPING", "The web server is stopping")
        return
      end

      response = context.response
      begin
        secure_headers(response)
        return failure(context, 403, "LOCAL_ONLY", "Local connections only") unless valid_host?(context)

        path = context.request.path
        prefix = "/#{@token}"
        return failure(context, 404, "NOT_FOUND", "Not found") unless path == prefix || path.starts_with?("#{prefix}/")
        suffix = path.byte_slice(prefix.bytesize, path.bytesize - prefix.bytesize)
        suffix = "/" if suffix.empty?

        case {context.request.method, suffix}
        when {"GET", "/"}
          serve_html(context)
        when {"GET", "/d4-igv.js"}
          serve_script(context)
        when {"GET", "/igv.min.js"}
          serve_igv_bundle(context)
        when {"GET", "/api/state"}
          send_state(context)
        when {"GET", "/api/features"}
          send_features(context)
        when {"POST", "/api/reference"}
          return failure(context, 403, "INVALID_ORIGIN", "Invalid request origin") unless valid_control_origin?(context)
          select_reference(context)
        when {"POST", "/api/desktop-goto"}
          return failure(context, 403, "INVALID_ORIGIN", "Invalid request origin") unless valid_control_origin?(context)
          desktop_goto(context)
        when {"GET", "/health"}
          response.content_type = "text/plain; charset=utf-8"
          response.print("ok\n")
        else
          if context.request.method.in?({"GET", "HEAD"}) && suffix.starts_with?("/reference/")
            serve_reference_resource(context, suffix.byte_slice("/reference/".bytesize, suffix.bytesize - "/reference/".bytesize))
          else
            failure(context, 404, "NOT_FOUND", "Not found")
          end
        end
      rescue ex
        STDERR.puts "D4 Plot web request failed: #{ex.class.name}: #{ex.message}" unless closed?
        failure(context, 500, "INTERNAL_ERROR", "Request failed") unless context.response.closed?
      ensure
        finish_request
      end
    end

    private def secure_headers(response : HTTP::Server::Response) : Nil
      reference = @mutex.synchronize { @snapshot.reference }
      connect_sources = ["'self'"] + reference.browser_connect_origins
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["X-Frame-Options"] = "DENY"
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
      response.headers["Content-Security-Policy"] = "default-src 'self'; connect-src #{connect_sources.join(' ')}; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; worker-src 'self' blob:; base-uri 'none'; frame-ancestors 'none'"
    end

    private def valid_host?(context : HTTP::Server::Context) : Bool
      context.request.headers["Host"]? == "127.0.0.1:#{@address.port}"
    end

    private def valid_control_origin?(context : HTTP::Server::Context) : Bool
      context.request.headers["Origin"]? == "http://127.0.0.1:#{@address.port}"
    end

    private def closed? : Bool
      @mutex.synchronize { @closed }
    end

    # Do not accept work after #close, while allowing an accepted request to
    # finish or observe the cancellation callback below.  #wait drains this
    # counter before returning, so native teardown cannot race an active HTTP
    # handler or Range transfer.
    private def begin_request : Bool
      @mutex.synchronize do
        if @closed
          false
        else
          @active_requests += 1
          true
        end
      end
    end

    private def finish_request : Nil
      @mutex.synchronize do
        @active_requests -= 1
        @request_drained.signal if @active_requests == 0
      end
    end

    private def serve_html(context : HTTP::Server::Context) : Nil
      html = HTML || raise "IGV viewer HTML asset is unavailable"
      context.response.content_type = "text/html; charset=utf-8"
      context.response.print(html)
    end

    private def serve_script(context : HTTP::Server::Context) : Nil
      script = SCRIPT || raise "IGV viewer JavaScript asset is unavailable"
      context.response.content_type = "text/javascript; charset=utf-8"
      context.response.print(script)
    end

    private def serve_igv_bundle(context : HTTP::Server::Context) : Nil
      bundle = BUNDLED_IGV || return failure(context, 503, "IGV_BUNDLE_MISSING", "IGV.js bundle is missing; run: node scripts/update-igv.mjs")
      context.response.content_type = "text/javascript; charset=utf-8"
      context.response.print(bundle)
    end

    private def send_state(context : HTTP::Server::Context) : Nil
      snapshot, selected_key, choices = @mutex.synchronize { {@snapshot, @selected_reference_key, @reference_options.keys.sort} }
      initial = requested_initial_region(context.request.query_params["locus"]?, snapshot) || snapshot.initial_region
      context.response.content_type = "application/json; charset=utf-8"
      JSON.build(context.response) do |json|
        json.object do
          json.field "revision", snapshot.revision
          json.field "locus", initial.to_s
          json.field "coordinateSystem", "0-based-half-open"
          json.field "igvReference" do
            json.raw(snapshot.igv_reference_config)
          end
          json.field "selectedReference", selected_key
          json.field "referenceInfo" do
            json.object do
              json.field "id", snapshot.reference.id
              json.field "name", snapshot.reference.name
              json.field "kind", snapshot.reference.kind.to_s.underscore
              json.field "dictionaryVerified", !snapshot.reference.dictionary.nil?
            end
          end
          json.field "desktopGotoAvailable", !snapshot.reference.dictionary.nil?
          json.field "referenceChoices" do
            json.array do
              choices.each do |key|
                json.object do
                  json.field "id", key
                  json.field "label", reference_choice_label(key, selected_key, snapshot)
                  json.field "selected", key == selected_key
                end
              end
            end
          end
          json.field "tracks" do
            json.array do
              snapshot.tracks.each do |track|
                json.object do
                  json.field "id", track.id
                  json.field "name", track.source.label
                  json.field "compatibility", track.compatibility.status.to_s.underscore
                end
              end
            end
          end
        end
      end
    end

    private def send_features(context : HTTP::Server::Context) : Nil
      snapshot = @mutex.synchronize { @snapshot }
      params = context.request.query_params
      revision = parameter(params, "revision", 128)
      return failure(context, 409, "SESSION_CHANGED", "The browser session changed; reload this page") unless revision == snapshot.revision

      track_id = parameter(params, "track", 128)
      track = track_id.try { |id| snapshot.track(id) }
      return failure(context, 404, "TRACK_NOT_FOUND", "Track not found") unless track
      chromosome = parameter(params, "chr", ContigDictionary::MAX_CONTIG_NAME_BYTES)
      return failure(context, 400, "INVALID_CHROMOSOME", "Invalid chromosome") unless chromosome && valid_chromosome_name?(chromosome)
      client_id = parameter(params, "client", 128)
      return failure(context, 400, "INVALID_CLIENT", "Invalid client id") unless client_id && /\A[A-Za-z0-9_-]+\z/.matches?(client_id)
      navigation_id = parse_non_negative_i64(parameter(params, "navigation", 32))
      return failure(context, 400, "INVALID_NAVIGATION", "Invalid navigation id") unless navigation_id

      start0 = parse_coordinate(parameter(params, "start", 64), round_up: false)
      end0 = parse_coordinate(parameter(params, "end", 64), round_up: true)
      bp_per_pixel = parse_positive_float(parameter(params, "bp_per_pixel", 64))
      return failure(context, 400, "INVALID_INTERVAL", "Invalid genomic interval") unless start0 && end0 && start0 < end0 && bp_per_pixel

      d4_chromosome = track.d4_chromosome_for(chromosome)
      return send_empty_features(context, snapshot, chromosome, true) unless d4_chromosome
      chromosome_size = track.source.chromosomes[d4_chromosome]?.try(&.to_i64)
      return send_empty_features(context, snapshot, chromosome, true) unless chromosome_size
      left = start0.clamp(0_i64, chromosome_size)
      right = end0.clamp(0_i64, chromosome_size)
      return send_empty_features(context, snapshot, chromosome, false) if left >= right

      layout = BinLayout.for_viewport(left, right, bp_per_pixel, chromosome_size, MAX_FEATURE_BINS)
      result = @signal_query.query(track.source, d4_chromosome, layout, snapshot.revision, client_id, navigation_id)
      context.response.content_type = "application/json; charset=utf-8"
      JSON.build(context.response) do |json|
        json.object do
          json.field "revision", snapshot.revision
          json.field "chr", chromosome
          json.field "coordinateSystem", "0-based-half-open"
          json.field "aggregation", "mean"
          json.field "binWidth", result.bin_width
          json.field "dataAvailable", true
          json.field "features" do
            json.array do
              result.bins.each do |bin|
                json.object do
                  json.field "start", bin.start0
                  json.field "end", bin.end0
                  json.field "value", bin.value
                end
              end
            end
          end
        end
      end
    rescue ex : SignalQueryBusy
      failure(context, 429, "QUERY_BUSY", ex.message || "D4 reader queue is full")
    rescue ex : SignalQueryCancelled
      failure(context, 409, "QUERY_CANCELLED", ex.message || "D4 query was superseded")
    rescue ex : SignalQueryBudgetExceeded
      failure(context, 422, "SCAN_BUDGET_EXCEEDED", ex.message || "D4 aggregation exceeds the streaming budget")
    rescue ex : SignalQueryClosed
      failure(context, 503, "SERVER_STOPPING", "The D4 reader is stopping")
    rescue ex : ArgumentError
      failure(context, 400, "INVALID_QUERY", ex.message || "Invalid D4 query")
    rescue ex
      # Source/OS exception text can contain an absolute D4 path. Keep that
      # diagnostic in the local process log, never in a browser response.
      STDERR.puts "D4 Plot D4 read failed: #{ex.class.name}: #{ex.message}"
      failure(context, 500, "READ_FAILED", "D4 read failed")
    end

    private def send_empty_features(context : HTTP::Server::Context, snapshot : IGVWebSession, chromosome : String, unavailable : Bool) : Nil
      context.response.content_type = "application/json; charset=utf-8"
      JSON.build(context.response) do |json|
        json.object do
          json.field "revision", snapshot.revision
          json.field "chr", chromosome
          json.field "coordinateSystem", "0-based-half-open"
          json.field "aggregation", "mean"
          json.field "binWidth", 0
          json.field "dataAvailable", !unavailable
          json.field "features" { json.array { } }
        end
      end
    end

    private def select_reference(context : HTTP::Server::Context) : Nil
      json = JSON.parse(read_control_body(context)).as_h
      id = json["id"]?.try(&.as_s?)
      return failure(context, 400, "INVALID_REFERENCE", "A reference id is required") unless id && id.bytesize <= 128
      snapshot = @mutex.synchronize do
        spec = @reference_options[id]? || raise ArgumentError.new("Unknown reference choice")
        next_snapshot = build_snapshot(@sources, @initial_region, spec)
        @selected_reference_key = id
        @selected_reference = spec
        @signal_query.activate_revision(next_snapshot.revision)
        @snapshot = next_snapshot
        next_snapshot
      end
      context.response.content_type = "application/json; charset=utf-8"
      context.response.print({revision: snapshot.revision}.to_json)
    rescue ex : JSON::ParseException | TypeCastError | ArgumentError | ReferenceValidationError
      failure(context, 400, "INVALID_REFERENCE", ex.message || "Invalid reference request")
    end

    private def desktop_goto(context : HTTP::Server::Context) : Nil
      json = JSON.parse(read_control_body(context)).as_h
      locus = json["locus"]?.try(&.as_s?)
      return failure(context, 400, "INVALID_LOCUS", "A locus is required") unless locus && locus.bytesize <= 1_024
      snapshot = @mutex.synchronize { @snapshot }
      unless snapshot.reference.dictionary
        return failure(context, 409, "DESKTOP_REFERENCE_UNVERIFIED", "Choose a reference with a verified contig dictionary before using IGV Desktop")
      end
      region = Region.resolve(locus, region_dictionary(snapshot))
      IGVDesktop.goto(region)
      context.response.content_type = "application/json; charset=utf-8"
      context.response.print(%({"ok":true}))
    rescue ex : JSON::ParseException | TypeCastError | ArgumentError
      failure(context, 400, "INVALID_LOCUS", ex.message || "Invalid locus")
    rescue ex
      failure(context, 502, "IGV_DESKTOP_UNAVAILABLE", ex.message || "IGV Desktop is unavailable")
    end

    private def serve_reference_resource(context : HTTP::Server::Context, route_id : String) : Nil
      return failure(context, 404, "NOT_FOUND", "Not found") if route_id.empty? || route_id.includes?('/') || route_id.bytesize > 128
      resource = @mutex.synchronize { @resource_routes[route_id]? }
      return failure(context, 404, "NOT_FOUND", "Not found") unless resource
      if resource.local_file?
        @range_files.handle(context, route_id, -> { closed? })
      else
        serve_generated_resource(context, resource)
      end
    end

    private def serve_generated_resource(context : HTTP::Server::Context, resource : ReferenceResource) : Nil
      return failure(context, 405, "METHOD_NOT_ALLOWED", "Only GET and HEAD are supported") unless context.request.method.in?({"GET", "HEAD"})
      content = resource.content.not_nil!
      return failure(context, 413, "RESOURCE_TOO_LARGE", "Generated reference resource is too large") if content.bytesize > MAX_GENERATED_RESOURCE_BYTES
      context.response.content_type = resource.content_type
      context.response.headers["Accept-Ranges"] = "none"
      context.response.content_length = content.bytesize
      context.response.print(content) if context.request.method == "GET"
    end

    private def requested_initial_region(raw : String?, snapshot : IGVWebSession) : Region?
      return unless raw && raw.bytesize <= 1_024
      Region.resolve(raw, region_dictionary(snapshot))
    rescue ArgumentError
      nil
    end

    private def region_dictionary(snapshot : IGVWebSession) : Hash(String, UInt32)
      dictionary = {} of String => UInt32
      if reference_dictionary = snapshot.reference.dictionary
        reference_dictionary.each { |contig| dictionary[contig.name] = contig.length.to_u32 }
      else
        snapshot.tracks.each do |track|
          track.source.chromosomes.each { |name, size| dictionary[name] ||= size }
        end
      end
      dictionary
    end

    private def install_reference_options(sources : Array(TrackSource), requested : ReferenceSpec?) : Nil
      contigs = ReferenceSpec.contigs_only(TrackSource.reference_chromosomes(sources))
      @reference_options = {
        "contigs-only" => contigs,
        "hg38"         => ReferenceSpec.preset("hg38"),
        "hg19"         => ReferenceSpec.preset("hg19"),
        "hs1"          => ReferenceSpec.preset("hs1"),
        "mm39"         => ReferenceSpec.preset("mm39"),
      }
      @reference_options["configured"] = requested if requested
    end

    private def refresh_contigs_option(sources : Array(TrackSource)) : Nil
      @reference_options["contigs-only"] = ReferenceSpec.contigs_only(TrackSource.reference_chromosomes(sources))
    end

    private def reference_choice_label(key : String, selected_key : String, snapshot : IGVWebSession) : String
      return snapshot.reference.name if key == selected_key
      case key
      when "contigs-only" then "Contigs only"
      when "configured"   then "Configured local reference"
      else                     key
      end
    end

    private def build_snapshot(sources : Array(TrackSource), initial : Region?, spec : ReferenceSpec) : IGVWebSession
      reference = spec.resolve
      installation = install_reference_resources(reference)
      begin
        tracks = sources.map do |source|
          IGVWebTrack.new(track_id_for(source), source, reference.compatibility_with(source.chromosomes))
        end
        provisional = IGVWebSession.new(Random::Secure.hex(16), reference, tracks,
          usable_initial_region(initial, reference, tracks), "")
        config = reference.igv_browser_config_json(installation.urls)
        session = IGVWebSession.new(provisional.revision, reference, tracks, provisional.initial_region, config)
        old_file_ids = @file_route_ids
        @file_route_ids = installation.file_route_ids
        @resource_routes = installation.routes
        old_file_ids.each { |id| @range_files.unregister(id) }
        session
      rescue ex
        installation.file_route_ids.each { |id| @range_files.unregister(id) }
        raise ex
      end
    end

    private def install_reference_resources(reference : ResolvedReference) : IGVWebResourceInstallation
      routes = {} of String => ReferenceResource
      file_ids = [] of String
      urls = {} of String => String
      begin
        reference.resources.each do |resource|
          route_id = if path = resource.path
                       id = @range_files.register(path, resource.content_type)
                       file_ids << id
                       id
                     else
                       Random::Secure.urlsafe_base64(18)
                     end
          routes[route_id] = resource
          urls[resource.id] = "#{url}reference/#{route_id}"
        end
        IGVWebResourceInstallation.new(routes, file_ids, urls)
      rescue ex
        file_ids.each { |id| @range_files.unregister(id) }
        raise ex
      end
    end

    # An opaque track id is stable while this server owns the same D4
    # file/internal-track pair. Snapshot revisions still protect old browser
    # tabs, but stable ids preserve an explicit browser track selection across
    # a reference change or GUI refresh.
    private def track_id_for(source : TrackSource) : String
      key = source.key
      @track_ids[key]? || begin
        id = Random::Secure.urlsafe_base64(18)
        @track_ids[key] = id
        id
      end
    end

    private def reconcile_track_ids(sources : Array(TrackSource)) : Nil
      active = {} of Tuple(String, String) => Bool
      sources.each { |source| active[source.key] = true }
      @track_ids.keys.each do |key|
        @track_ids.delete(key) unless active.has_key?(key)
      end
    end

    private def default_region(reference : ResolvedReference, tracks : Array(IGVWebTrack)) : Region
      if dictionary = reference.dictionary
        dictionary.each do |contig|
          if track = tracks.find { |candidate| candidate.d4_chromosome_for(contig.name) }
            d4_name = track.d4_chromosome_for(contig.name).not_nil!
            return bounded_region(contig.name, track.source.chromosomes[d4_name])
          end
        end
        # A custom reference and every D4 track may be mutually incompatible.
        # Keep the browser on a real reference contig so each track can report
        # dataAvailable:false, rather than inventing an IGV locus that the
        # reference does not contain.
        first = dictionary.entries.first
        return bounded_region(first.name, first.length.to_u32)
      end
      tracks.each do |track|
        if chromosome = track.source.chromosomes.first?
          return bounded_region(chromosome[0], chromosome[1])
        end
      end
      raise ArgumentError.new("No non-empty D4 chromosome is available")
    end

    # A GUI can replace its tracks while retaining a stale visible locus. Never
    # pass such a locus to IGV.js: it could point beyond a new track's contig
    # or use a name no longer mapped by the selected reference.
    private def usable_initial_region(initial : Region?, reference : ResolvedReference, tracks : Array(IGVWebTrack)) : Region
      return default_region(reference, tracks) unless initial
      if dictionary = reference.dictionary
        length = dictionary[initial.chromosome]
        return default_region(reference, tracks) unless length && initial.end1 <= length
      end
      tracks.each do |track|
        next unless d4_name = track.d4_chromosome_for(initial.chromosome)
        next unless size = track.source.chromosomes[d4_name]?
        return initial if initial.end1 <= size
      end
      default_region(reference, tracks)
    end

    private def bounded_region(chromosome : String, size : UInt32) : Region
      Region.bounded(chromosome, 0_i64, Math.min(100_000_i64, size.to_i64), size)
    end

    private def read_control_body(context : HTTP::Server::Context) : String
      header = context.request.headers["Content-Length"]?
      if header
        length = header.to_i64?
        raise ArgumentError.new("Invalid Content-Length") unless length && length >= 0 && length <= MAX_CONTROL_BODY_BYTES
      end
      io = context.request.body || return ""
      memory = IO::Memory.new
      buffer = Bytes.new(1_024)
      total = 0
      while count = io.read(buffer)
        break if count == 0
        total += count
        raise ArgumentError.new("Request body is too large") if total > MAX_CONTROL_BODY_BYTES
        memory.write(buffer[0, count])
      end
      String.new(memory.to_slice)
    end

    private def parameter(params : URI::Params, name : String, max_bytes : Int32) : String?
      value = params[name]?
      return unless value && value.bytesize <= max_bytes
      value
    end

    private def parse_coordinate(raw : String?, round_up : Bool) : Int64?
      return unless raw
      value = BigDecimal.new(raw)
      (round_up ? value.ceil : value.floor).to_i64
    rescue InvalidBigDecimalException | ArgumentError | OverflowError
      nil
    end

    private def parse_positive_float(raw : String?) : Float64?
      return unless raw
      value = raw.to_f64?
      value if value && value.finite? && value > 0.0
    end

    private def parse_non_negative_i64(raw : String?) : Int64?
      return unless raw && /\A[0-9]+\z/.matches?(raw)
      raw.to_i64?
    end

    private def valid_chromosome_name?(name : String) : Bool
      !name.empty? && !name.includes?('\0') && !/\s/.matches?(name)
    end

    private def failure(context : HTTP::Server::Context, status : Int32, code : String, message : String) : Nil
      return if context.response.closed?
      context.response.status_code = status
      context.response.content_type = "application/json; charset=utf-8"
      JSON.build(context.response) do |json|
        json.object do
          json.field "error", code
          json.field "message", message
        end
      end
    end
  end
end
