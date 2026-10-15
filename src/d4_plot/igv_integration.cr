require "http/client"
require "uri"
require "./region"

module D4Plot
  # Small, deliberately one-way adapter for IGV Desktop's external-control
  # listener.  It never starts IGV and it does not change the active genome
  # when navigating to a locus.
  module IGVDesktop
    DEFAULT_PORT            = 60_151
    GOTO_CONNECT_TIMEOUT    = 2.seconds
    GOTO_READ_TIMEOUT       = 5.seconds
    MAX_RESPONSE_BODY_BYTES = 4_096

    def self.goto_path(region : Region) : String
      validate_region!(region)
      "/goto?#{URI::Params.encode({"locus" => region.to_s})}"
    end

    def self.goto(region : Region, port : Int32 = DEFAULT_PORT) : Nil
      validate_port!(port)
      request(goto_path(region), port, GOTO_CONNECT_TIMEOUT, GOTO_READ_TIMEOUT)
    end

    # This is intentionally kept private to the integration layer.  Adding a
    # Desktop command must define a separate explicit action; callers should
    # never accidentally send a genome-changing command as part of goto.
    private def self.request(path : String, port : Int32, connect_timeout : Time::Span, read_timeout : Time::Span) : Nil
      client = HTTP::Client.new("127.0.0.1", port)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout
      client.exec("GET", path) do |response|
        detail = response_excerpt(response.body_io, MAX_RESPONSE_BODY_BYTES)
        unless response.success?
          suffix = detail.empty? ? "" : ": #{detail}"
          raise "IGV Desktop returned HTTP #{response.status_code}#{suffix}"
        end
        # Some IGV versions answer a 2xx status with a textual error.  Do not
        # silently report a successful navigation in that case.
        if detail.downcase.includes?("error")
          raise "IGV Desktop rejected the command: #{detail}"
        end
      end
    ensure
      client.try(&.close)
    end

    private def self.response_excerpt(io : IO, limit : Int32) : String
      buffer = Bytes.new(limit + 1)
      read = 0
      while read < buffer.size
        count = io.read(buffer[read..])
        break if count == 0
        read += count
      end
      excerpt = String.new(buffer[0, Math.min(read, limit)]).strip
      read > limit ? "#{excerpt}…" : excerpt
    end

    private def self.validate_region!(region : Region) : Nil
      raise ArgumentError.new("Invalid genomic region") unless region.valid?
      chromosome = region.chromosome
      raise ArgumentError.new("Invalid chromosome name") if chromosome.empty? || chromosome.bytes.any? { |byte| byte < 0x20 || byte == 0x7f_u8 }
    end

    private def self.validate_port!(port : Int32) : Nil
      raise ArgumentError.new("Invalid IGV port") unless (1..65_535).includes?(port)
    end
  end

  module BrowserLauncher
    def self.open(url : String) : Nil
      uri = URI.parse(url)
      raise ArgumentError.new("Only HTTP(S) browser URLs are supported") unless uri.scheme.in?({"http", "https"})

      # Pass URL data as an argument rather than through a shell.
      {% if flag?(:win32) %}
        ensure_opened("rundll32", ["url.dll,FileProtocolHandler", url])
      {% elsif flag?(:darwin) %}
        ensure_opened("open", [url])
      {% else %}
        ensure_opened("xdg-open", [url])
      {% end %}
    end

    private def self.ensure_opened(command : String, arguments : Array(String)) : Nil
      raise "Could not open web browser" unless Process.run(command, arguments).success?
    end
  end
end
