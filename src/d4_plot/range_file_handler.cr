require "http/server"
require "random/secure"

module D4Plot
  # A capability-based file responder for local reference resources.
  #
  # Callers register trusted files during server setup and expose only the
  # returned opaque ID in a route.  Request data is never interpreted as a
  # filesystem path.  Each request opens a separate descriptor, so seeks made
  # for one HTTP request cannot affect another.
  class RangeFileHandler
    # A non-range response is deliberately capped.  Reference FASTA data must
    # be requested with a byte range; small index files can still be fetched in
    # their entirety.
    DEFAULT_MAX_FULL_RESPONSE_BYTES = 8_i64 * 1024 * 1024

    # This is the only request-sized read buffer allocated by the handler.
    COPY_BUFFER_SIZE = 64 * 1024

    private RESOURCE_ID_BYTES = 32

    class RegistrationError < ArgumentError
    end

    private class ResourceUnavailable < Exception
    end

    private class RequestCancelled < Exception
    end

    private struct Resource
      getter canonical_path : String
      getter content_type : String
      getter identity : File::Info
      getter size : Int64
      getter modified_ms : Int64

      def initialize(@canonical_path : String, @content_type : String, @identity : File::Info)
        @size = @identity.size
        @modified_ms = @identity.modification_time.to_unix_ms
      end

      def unchanged?(info : File::Info) : Bool
        info.same_file?(@identity) && info.size == @size && info.modification_time.to_unix_ms == @modified_ms
      end
    end

    private struct ByteRange
      getter first : Int64
      getter last : Int64

      def initialize(@first : Int64, @last : Int64)
      end

      def size : Int64
        @last - @first + 1_i64
      end
    end

    getter max_full_response_bytes : Int64

    @resources : Hash(String, Resource)
    @resources_lock : Thread::Mutex
    @transfer_slots : Channel(Nil)

    def initialize(@max_full_response_bytes : Int64 = DEFAULT_MAX_FULL_RESPONSE_BYTES,
                   max_concurrent_transfers : Int32 = 8)
      raise ArgumentError.new("Full-response limit cannot be negative") if @max_full_response_bytes < 0
      raise ArgumentError.new("Transfer limit must be positive") if max_concurrent_transfers <= 0
      @resources = {} of String => Resource
      @resources_lock = Thread::Mutex.new
      @transfer_slots = Channel(Nil).new(max_concurrent_transfers)
      max_concurrent_transfers.times { @transfer_slots.send(nil) }
    end

    # Registers a local regular file and returns an unguessable, URL-safe ID.
    # The supplied path may itself be a symlink, but its resolved canonical
    # target is what is registered.  Later symlink or replacement changes are
    # rejected before any bytes are sent.
    def register(path : String | Path, content_type : String) : String
      validate_content_type!(content_type)
      canonical_path = File.realpath(path)
      resource = resource_for_registration(canonical_path, content_type)

      loop do
        id = Random::Secure.urlsafe_base64(RESOURCE_ID_BYTES)
        inserted = false
        @resources_lock.synchronize do
          unless @resources.has_key?(id)
            @resources[id] = resource
            inserted = true
          end
        end
        return id if inserted
      end
    rescue ex : File::Error
      raise RegistrationError.new("Registered resources must be readable regular files")
    end

    # Removes an ID from the capability registry.  In-flight requests keep the
    # descriptor they already verified; future requests receive 404.
    def unregister(id : String) : Bool
      @resources_lock.synchronize { !@resources.delete(id).nil? }
    end

    def registered?(id : String) : Bool
      @resources_lock.synchronize { @resources.has_key?(id) }
    end

    # Completes a GET or HEAD request for a registered resource ID.  A router
    # should call this only after matching its own authenticated local route.
    def handle(context : HTTP::Server::Context, id : String, cancelled : Proc(Bool)? = nil) : Nil
      request_method = context.request.method
      unless request_method == "GET" || request_method == "HEAD"
        respond_method_not_allowed(context)
        return
      end

      resource = resource_for(id)
      unless resource
        respond_not_found(context)
        return
      end

      unless acquire_transfer_slot
        respond_busy(context)
        return
      end
      begin
        raise RequestCancelled.new if cancelled.try(&.call)
        serve(context, resource, cancelled)
      ensure
        @transfer_slots.send(nil)
      end
    rescue ex : ResourceUnavailable
      # Do not disclose whether a formerly valid resource was deleted,
      # replaced, or redirected through a symlink.
      respond_not_found(context)
    rescue ex : RequestCancelled
      respond_stopping(context) unless context.response.closed?
    end

    private def resource_for_registration(canonical_path : String, content_type : String) : Resource
      path_info = File.info(canonical_path, false)
      unless regular_file_without_symlink?(path_info)
        raise RegistrationError.new("Registered resources must be regular files")
      end

      file = File.open(canonical_path, "rb")
      begin
        opened_info = file.info
        unless opened_info.file? && path_info.same_file?(opened_info) && canonical_path_current?(canonical_path)
          raise RegistrationError.new("Resource changed while it was being registered")
        end
        Resource.new(canonical_path, content_type, opened_info)
      ensure
        file.close
      end
    end

    # Checks the pathname both before and after opening.  The second check plus
    # fstat on the request-owned descriptor closes the usual check/open race:
    # a different file may be opened transiently, but it is never served.
    private def open_resource(resource : Resource) : Tuple(File, Int64)
      ensure_current_path!(resource)
      file = File.open(resource.canonical_path, "rb")
      begin
        opened_info = file.info
        unless opened_info.file? && resource.unchanged?(opened_info)
          raise ResourceUnavailable.new
        end
        ensure_current_path!(resource)
        {file, opened_info.size}
      rescue ex
        file.close
        raise ex
      end
    rescue ex : File::Error
      raise ResourceUnavailable.new
    end

    private def ensure_current_path!(resource : Resource) : Nil
      raise ResourceUnavailable.new unless canonical_path_current?(resource.canonical_path)

      path_info = File.info(resource.canonical_path, false)
      unless regular_file_without_symlink?(path_info) && resource.unchanged?(path_info)
        raise ResourceUnavailable.new
      end
    end

    private def canonical_path_current?(canonical_path : String) : Bool
      File.realpath(canonical_path) == canonical_path
    end

    private def regular_file_without_symlink?(info : File::Info) : Bool
      info.file? && !info.symlink?
    end

    private def resource_for(id : String) : Resource?
      @resources_lock.synchronize { @resources[id]? }
    end

    # A bounded, non-blocking semaphore.  Holding a request connection open
    # while waiting here would let slow reference downloads monopolize the
    # HTTP server, so callers receive a retryable response instead.
    private def acquire_transfer_slot : Bool
      select
      when @transfer_slots.receive
        true
      else
        false
      end
    end

    private def serve(context : HTTP::Server::Context, resource : Resource, cancelled : Proc(Bool)?) : Nil
      file, file_size = open_resource(resource)
      begin
        raise RequestCancelled.new if cancelled.try(&.call)
        if range_header = context.request.headers["Range"]?
          range = parse_single_byte_range(range_header, file_size)
          unless range
            respond_range_not_satisfiable(context, file_size)
            return
          end
          serve_range(context, file, resource, file_size, range, cancelled)
        elsif file_size > @max_full_response_bytes
          respond_range_required(context)
        else
          serve_full(context, file, resource, file_size, cancelled)
        end
      ensure
        file.close
      end
    end

    private def serve_full(context : HTTP::Server::Context, file : File, resource : Resource, file_size : Int64,
                           cancelled : Proc(Bool)?) : Nil
      response = context.response
      response.status = HTTP::Status::OK
      set_file_headers(response, resource, file_size)
      return if context.request.method == "HEAD"

      copy_exact(file, response, file_size, cancelled)
    end

    private def serve_range(context : HTTP::Server::Context, file : File, resource : Resource,
                            file_size : Int64, range : ByteRange, cancelled : Proc(Bool)?) : Nil
      file.seek(range.first, IO::Seek::Set) unless context.request.method == "HEAD"

      response = context.response
      response.status = HTTP::Status::PARTIAL_CONTENT
      set_file_headers(response, resource, range.size)
      response.headers["Content-Range"] = "bytes #{range.first}-#{range.last}/#{file_size}"
      return if context.request.method == "HEAD"

      copy_exact(file, response, range.size, cancelled)
    end

    private def set_file_headers(response : HTTP::Server::Response, resource : Resource, length : Int64) : Nil
      response.content_type = resource.content_type
      response.headers["Accept-Ranges"] = "bytes"
      # This server does not install a compression handler. Keep range bytes
      # literal so offsets and the exact Content-Length stay meaningful.
      response.content_length = length
    end

    private def respond_range_not_satisfiable(context : HTTP::Server::Context, file_size : Int64) : Nil
      response = context.response
      response.status = HTTP::Status::RANGE_NOT_SATISFIABLE
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Range"] = "bytes */#{file_size}"
      response.content_length = 0_i64
    end

    private def respond_range_required(context : HTTP::Server::Context) : Nil
      response = context.response
      response.status = HTTP::Status::PAYLOAD_TOO_LARGE
      response.headers["Accept-Ranges"] = "bytes"
      response.content_length = 0_i64
    end

    private def respond_method_not_allowed(context : HTTP::Server::Context) : Nil
      response = context.response
      response.status = HTTP::Status::METHOD_NOT_ALLOWED
      response.headers["Allow"] = "GET, HEAD"
      response.content_length = 0_i64
    end

    private def respond_not_found(context : HTTP::Server::Context) : Nil
      response = context.response
      response.status = HTTP::Status::NOT_FOUND
      response.content_length = 0_i64
    end

    private def respond_busy(context : HTTP::Server::Context) : Nil
      response = context.response
      response.status_code = 429
      response.headers["Retry-After"] = "1"
      response.content_length = 0_i64
    end

    private def respond_stopping(context : HTTP::Server::Context) : Nil
      response = context.response
      response.status = HTTP::Status::SERVICE_UNAVAILABLE
      response.content_length = 0_i64
    end

    private def copy_exact(file : File, output : IO, byte_count : Int64, cancelled : Proc(Bool)?) : Nil
      buffer = Bytes.new(COPY_BUFFER_SIZE)
      remaining = byte_count
      while remaining > 0
        raise RequestCancelled.new if cancelled.try(&.call)
        count = remaining > COPY_BUFFER_SIZE ? COPY_BUFFER_SIZE : remaining.to_i
        bytes_read = file.read(buffer[0, count])
        raise IO::EOFError.new("Registered resource changed while it was being read") if bytes_read == 0
        output.write(buffer[0, bytes_read])
        remaining -= bytes_read
      end
    end

    # Only one byte-range is intentionally supported.  Ignoring additional
    # ranges would turn a bounded request into a potentially huge 200 response.
    private def parse_single_byte_range(header : String, file_size : Int64) : ByteRange?
      value = header.strip
      return unless value.bytesize >= 6 && value.byte_slice(0, 6).downcase == "bytes="

      specification = value.byte_slice(6)
      return if specification.empty? || specification.includes?(',')

      dash = specification.index('-')
      return unless dash
      return if specification.index('-', dash + 1)

      start_text = specification.byte_slice(0, dash)
      finish_start = dash + 1
      finish_text = specification.byte_slice(finish_start, specification.bytesize - finish_start)

      if start_text.empty?
        suffix_length = parse_non_negative_i64(finish_text)
        return unless suffix_length && suffix_length > 0 && file_size > 0

        first = suffix_length >= file_size ? 0_i64 : file_size - suffix_length
        return ByteRange.new(first, file_size - 1_i64)
      end

      first = parse_non_negative_i64(start_text)
      return unless first && first < file_size

      last = if finish_text.empty?
               file_size - 1_i64
             else
               requested_last = parse_non_negative_i64(finish_text)
               return unless requested_last && requested_last >= first
               requested_last < file_size ? requested_last : file_size - 1_i64
             end
      ByteRange.new(first, last)
    end

    private def parse_non_negative_i64(value : String) : Int64?
      return if value.empty?

      number = 0_i64
      value.each_byte do |byte|
        return unless byte >= 48_u8 && byte <= 57_u8
        digit = (byte - 48_u8).to_i64
        return if number > (Int64::MAX - digit) // 10_i64
        number = number * 10_i64 + digit
      end
      number
    end

    private def validate_content_type!(content_type : String) : Nil
      raise RegistrationError.new("Content type cannot be empty") if content_type.empty?
      content_type.each_byte do |byte|
        unless byte >= 0x20 && byte <= 0x7e
          raise RegistrationError.new("Content type contains an unsafe HTTP header character")
        end
      end
    end
  end
end
