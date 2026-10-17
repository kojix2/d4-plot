require "json"

module D4Plot
  # Raised before a reference is made available to a browser or reader.  In
  # particular, this class is used instead of trying to repair a missing FAI.
  class ReferenceValidationError < ArgumentError
  end

  # A contig length is deliberately represented as Int64 at this boundary.
  # The current D4 reader has UInt32 coordinates, so larger values are rejected
  # while parsing rather than being truncated.
  record Contig, name : String, length : Int64

  # An ordered, validated chromosome dictionary.  Order comes from the source
  # FAI/chrom.sizes file and is retained for IGV's chromosome chooser.
  class ContigDictionary
    MAX_CONTIGS           = 1_000_000
    MAX_CONTIG_NAME_BYTES =     1_024

    @entries : Array(Contig)
    @length_by_name : Hash(String, Int64)

    def initialize(entries : Enumerable(Contig))
      @entries = entries.to_a
      raise ReferenceValidationError.new("Reference dictionary is empty") if @entries.empty?
      raise ReferenceValidationError.new("Reference dictionary has too many contigs") if @entries.size > MAX_CONTIGS

      @length_by_name = {} of String => Int64
      @entries.each do |entry|
        self.class.validate_name!(entry.name)
        self.class.validate_length!(entry.length, entry.name)
        raise ReferenceValidationError.new("Duplicate contig in reference dictionary: #{entry.name}") if @length_by_name.has_key?(entry.name)
        @length_by_name[entry.name] = entry.length
      end
    end

    def self.from_hash(contigs : Hash(String, UInt32)) : self
      new(contigs.map { |name, length| Contig.new(name, length.to_i64) })
    end

    def self.from_hash(contigs : Hash(String, Int64)) : self
      new(contigs.map { |name, length| Contig.new(name, length) })
    end

    def self.from_hash(contigs : Hash(String, Int32)) : self
      new(contigs.map { |name, length| Contig.new(name, length.to_i64) })
    end

    def self.from_fai(path : String) : self
      FaiIndex.read(path).dictionary
    end

    # UCSC chrom.sizes is intentionally parsed separately from FAI: it has
    # only two fields and no byte-offset semantics.
    def self.from_chrom_sizes(path : String) : self
      checked = ReferenceFiles.local_file(path, "chrom.sizes")
      entries = [] of Contig
      File.open(checked) do |file|
        ReferenceFiles.each_bounded_line(file, "chrom.sizes") do |line, line_number|
          row = line.chomp
          next if row.empty? || row.starts_with?('#')
          fields = row.split('\t')
          unless fields.size == 2
            raise ReferenceValidationError.new("chrom.sizes line #{line_number} must have exactly two tab-separated fields")
          end
          entries << Contig.new(fields[0], ReferenceFiles.unsigned_length!(fields[1], "chrom.sizes line #{line_number}"))
        end
      end
      new(entries)
    rescue ex : ReferenceValidationError
      raise ex
    rescue ex
      raise ReferenceValidationError.new("Could not read chrom.sizes #{path}: #{ex.message || ex.class.name}")
    end

    def entries : Array(Contig)
      @entries.dup
    end

    def each(&) : Nil
      @entries.each { |entry| yield entry }
      nil
    end

    def [](name : String) : Int64?
      @length_by_name[name]?
    end

    def includes?(name : String) : Bool
      @length_by_name.has_key?(name)
    end

    def size : Int32
      @entries.size
    end

    def to_h : Hash(String, Int64)
      @length_by_name.dup
    end

    def chrom_sizes_text : String
      String.build do |io|
        @entries.each { |entry| io << entry.name << '\t' << entry.length << '\n' }
      end
    end

    def self.validate_name!(name : String) : Nil
      if name.empty? || name.bytesize > MAX_CONTIG_NAME_BYTES || name.includes?('\0') || /\s/.matches?(name)
        raise ReferenceValidationError.new("Invalid contig name: #{name.inspect}")
      end
    end

    def self.validate_length!(length : Int64, name : String) : Nil
      if length <= 0 || length > UInt32::MAX.to_i64
        raise ReferenceValidationError.new("Contig #{name.inspect} has unsupported length #{length}; maximum is #{UInt32::MAX}")
      end
    end
  end

  record FaiEntry, contig : Contig, offset : Int64, bases_per_line : Int64, bytes_per_line : Int64

  # Parsed FAI metadata.  This performs inexpensive structural checks without
  # scanning the entire FASTA, which matters for multi-gigabyte references.
  class FaiIndex
    MAX_LINE_BYTES         = 16 * 1024
    MAX_FASTA_HEADER_BYTES = MAX_LINE_BYTES

    getter entries : Array(FaiEntry)
    getter dictionary : ContigDictionary

    def initialize(@entries : Array(FaiEntry))
      @dictionary = ContigDictionary.new(@entries.map(&.contig))
    end

    def self.read(path : String) : self
      checked = ReferenceFiles.local_file(path, "FAI")
      entries = [] of FaiEntry
      names = {} of String => Bool
      File.open(checked) do |file|
        ReferenceFiles.each_bounded_line(file, "FAI") do |line, line_number|
          row = line.chomp
          raise ReferenceValidationError.new("FAI line #{line_number} is empty") if row.empty?
          fields = row.split('\t')
          unless fields.size == 5
            raise ReferenceValidationError.new("FAI line #{line_number} must have exactly five tab-separated fields")
          end

          name = fields[0]
          ContigDictionary.validate_name!(name)
          raise ReferenceValidationError.new("Duplicate FAI contig: #{name}") if names.has_key?(name)
          names[name] = true

          length = ReferenceFiles.unsigned_length!(fields[1], "FAI line #{line_number}")
          offset = ReferenceFiles.non_negative_int64!(fields[2], "FAI line #{line_number} offset")
          bases_per_line = ReferenceFiles.positive_int64!(fields[3], "FAI line #{line_number} bases per line")
          bytes_per_line = ReferenceFiles.positive_int64!(fields[4], "FAI line #{line_number} bytes per line")
          if bytes_per_line < bases_per_line
            raise ReferenceValidationError.new("FAI line #{line_number} has bytes per line smaller than bases per line")
          end
          entries << FaiEntry.new(Contig.new(name, length), offset, bases_per_line, bytes_per_line)
        end
      end
      new(entries)
    rescue ex : ReferenceValidationError
      raise ex
    rescue ex
      raise ReferenceValidationError.new("Could not read FAI #{path}: #{ex.message || ex.class.name}")
    end

    # Validate the header identity, offsets, and representative line geometry
    # with bounded reads per contig. This detects an FAI paired with the wrong
    # FASTA without turning validation into a full FASTA scan.
    def validate_for_fasta!(fasta_path : String) : Nil
      size = File.size(fasta_path).to_i64
      raise ReferenceValidationError.new("FASTA is empty: #{fasta_path}") if size <= 0
      File.open(fasta_path, "rb") do |fasta|
        @entries.each do |entry|
          first = entry.offset
          last = last_base_offset(entry)
          if first < 0 || first >= size || last < first || last >= size
            raise ReferenceValidationError.new("FAI entry #{entry.contig.name.inspect} points outside FASTA #{fasta_path}")
          end
          validate_header!(fasta, entry)
          validate_sequence_byte!(fasta, first, entry.contig.name)
          validate_line_geometry!(fasta, entry)
          validate_sequence_byte!(fasta, last, entry.contig.name)
          validate_sequence_end!(fasta, last, size, entry.contig.name)
        end
      end
    rescue ex : ReferenceValidationError
      raise ex
    rescue ex
      raise ReferenceValidationError.new("Could not validate FAI against FASTA #{fasta_path}: #{ex.message || ex.class.name}")
    end

    private def last_base_offset(entry : FaiEntry) : Int64
      last_index = entry.contig.length - 1
      rows = last_index // entry.bases_per_line
      column = last_index % entry.bases_per_line
      limit = Int64::MAX - entry.offset - column
      if limit < 0 || (rows > 0 && entry.bytes_per_line > limit // rows)
        raise ReferenceValidationError.new("FAI entry #{entry.contig.name.inspect} has overflowing byte offsets")
      end
      entry.offset + rows * entry.bytes_per_line + column
    end

    # An FAI offset must name the first byte after the matching FASTA header,
    # rather than merely an arbitrary printable byte somewhere in the file.
    # Limit the header look-back so a malicious unterminated header cannot make
    # reference validation scan a large FASTA.
    private def validate_header!(fasta : File, entry : FaiEntry) : Nil
      name = entry.contig.name
      header_end = header_end_before!(fasta, entry.offset, name)
      header, header_start = header_before!(fasta, header_end, name)
      validate_header_name!(header, header_start, name)
    end

    private def header_end_before!(fasta : File, offset : Int64, name : String) : Int64
      raise ReferenceValidationError.new("FAI entry #{name.inspect} does not follow a FASTA header") if offset <= 0

      terminator_size = line_terminator_size_before!(fasta, offset, name)
      header_end = offset - terminator_size
      raise ReferenceValidationError.new("FAI entry #{name.inspect} does not follow a FASTA header") if header_end <= 0
      header_end
    end

    private def line_terminator_size_before!(fasta : File, offset : Int64, name : String) : Int64
      case fasta_byte_at!(fasta, offset - 1_i64, name)
      when '\n'.ord
        offset >= 2_i64 && fasta_byte_at!(fasta, offset - 2_i64, name) == '\r'.ord ? 2_i64 : 1_i64
      when '\r'.ord
        1_i64
      else
        raise ReferenceValidationError.new("FAI entry #{name.inspect} does not follow a FASTA header")
      end
    end

    private def header_before!(fasta : File, header_end : Int64, name : String) : Tuple(Bytes, Int32)
      window_start = header_end > MAX_FASTA_HEADER_BYTES ? header_end - MAX_FASTA_HEADER_BYTES : 0_i64
      header = Bytes.new((header_end - window_start).to_i)
      fasta.seek(window_start, IO::Seek::Set)
      fasta.read_fully(header)

      header_start = header_start_in(header)
      if header_start.nil? && window_start != 0_i64
        raise ReferenceValidationError.new("FASTA header for FAI entry #{name.inspect} is too long to validate")
      end
      {header, header_start || 0}
    end

    private def header_start_in(header : Bytes) : Int32?
      index = header.size
      while index > 0
        index -= 1
        return index + 1 if header[index] == '\n'.ord || header[index] == '\r'.ord
      end
    end

    private def validate_header_name!(header : Bytes, header_start : Int32, name : String) : Nil
      unless header_start < header.size && header[header_start] == '>'.ord
        raise ReferenceValidationError.new("FAI entry #{name.inspect} does not match its FASTA header")
      end

      name_bytes = name.to_slice
      cursor = header_start + 1
      name_bytes.each do |byte|
        if cursor >= header.size || header[cursor] != byte
          raise ReferenceValidationError.new("FAI entry #{name.inspect} does not match its FASTA header")
        end
        cursor += 1
      end
      if cursor < header.size && !header_token_separator?(header[cursor])
        raise ReferenceValidationError.new("FAI entry #{name.inspect} does not match its FASTA header")
      end
    end

    # A multi-line sequence needs a fixed-width separator between each full
    # line. Sampling the first and last such boundary catches mismatched FAI
    # line widths while keeping validation constant in the sequence length.
    private def validate_line_geometry!(fasta : File, entry : FaiEntry) : Nil
      return unless entry.contig.length > entry.bases_per_line

      last_row = (entry.contig.length - 1_i64) // entry.bases_per_line
      validate_line_break_after_row!(fasta, entry, 0_i64)
      validate_line_break_after_row!(fasta, entry, last_row - 1_i64) if last_row > 1_i64

      last_row_start = entry.offset + last_row * entry.bytes_per_line
      validate_sequence_byte!(fasta, last_row_start, entry.contig.name)
    end

    private def validate_line_break_after_row!(fasta : File, entry : FaiEntry, row : Int64) : Nil
      name = entry.contig.name
      row_start = entry.offset + row * entry.bytes_per_line
      row_end = row_start + entry.bases_per_line
      validate_sequence_byte!(fasta, row_end - 1_i64, name)

      separator_size = entry.bytes_per_line - entry.bases_per_line
      case separator_size
      when 1_i64
        byte = fasta_byte_at!(fasta, row_end, name)
        unless byte == '\n'.ord || byte == '\r'.ord
          raise ReferenceValidationError.new("FAI entry #{name.inspect} has invalid FASTA line geometry")
        end
      when 2_i64
        unless fasta_byte_at!(fasta, row_end, name) == '\r'.ord && fasta_byte_at!(fasta, row_end + 1_i64, name) == '\n'.ord
          raise ReferenceValidationError.new("FAI entry #{name.inspect} has invalid FASTA line geometry")
        end
      else
        raise ReferenceValidationError.new("FAI entry #{name.inspect} has invalid FASTA line geometry")
      end
      validate_sequence_byte!(fasta, row_start + entry.bytes_per_line, name)
    end

    private def validate_sequence_byte!(fasta : File, offset : Int64, name : String) : Nil
      byte = fasta_byte_at!(fasta, offset, name)
      if byte == '\n'.ord || byte == '\r'.ord || byte == '>'.ord || byte < 33
        raise ReferenceValidationError.new("FAI entry #{name.inspect} does not point to FASTA sequence data")
      end
    end

    # The declared final base must end its FASTA record. Without this check an
    # FAI can claim a shorter contig whose first and calculated last bytes
    # happen to be nucleotides, causing the browser to silently truncate the
    # reference. A final row may omit its line terminator, so EOF is valid too.
    # htslib also permits blank lines between records; consume only a bounded
    # amount of those separators before requiring the next header or EOF.
    private def validate_sequence_end!(fasta : File, last : Int64, size : Int64, name : String) : Nil
      next_offset = last + 1_i64
      return if next_offset == size

      case fasta_byte_at!(fasta, next_offset, name)
      when '\n'.ord
        next_offset += 1_i64
      when '\r'.ord
        next_offset += 1_i64
        if next_offset < size && fasta_byte_at!(fasta, next_offset, name) == '\n'.ord
          next_offset += 1_i64
        end
      else
        raise ReferenceValidationError.new("FAI entry #{name.inspect} does not end at a FASTA sequence boundary")
      end

      return if next_offset == size
      blank_bytes = 0_i64
      loop do
        following = fasta_byte_at!(fasta, next_offset, name)
        return if following == '>'.ord

        # Empty rows are valid between records, but bases after one would mean
        # this FAI entry omitted part of its own sequence. Keep this bounded so
        # a hostile file cannot turn per-entry validation into a long scan.
        unless following == '\n'.ord || following == '\r'.ord
          raise ReferenceValidationError.new("FAI entry #{name.inspect} does not end at a FASTA sequence boundary")
        end
        separator_start = next_offset
        next_offset += 1_i64
        if following == '\r'.ord && next_offset < size && fasta_byte_at!(fasta, next_offset, name) == '\n'.ord
          next_offset += 1_i64
        end
        blank_bytes += next_offset - separator_start
        if blank_bytes > MAX_LINE_BYTES || next_offset == size
          return if next_offset == size
          raise ReferenceValidationError.new("FAI entry #{name.inspect} has too many blank lines before the next FASTA header")
        end
      end
    end

    private def fasta_byte_at!(fasta : File, offset : Int64, name : String) : UInt8
      fasta.seek(offset, IO::Seek::Set)
      fasta.read_byte || raise ReferenceValidationError.new("FAI entry #{name.inspect} points outside FASTA sequence data")
    end

    private def header_token_separator?(byte : UInt8) : Bool
      byte <= 32_u8
    end
  end

  # Maps an alternate (for example `1`) to a canonical reference contig (for
  # example `chr1`).  The direction is intentional: callers compare a track
  # contig to the reference dictionary, never silently rewrite the dictionary.
  class ReferenceAliases
    @canonical_by_alias : Hash(String, String)

    def initialize(pairs : Hash(String, String) = {} of String => String)
      @canonical_by_alias = {} of String => String
      pairs.each do |alternate, canonical|
        ContigDictionary.validate_name!(alternate)
        ContigDictionary.validate_name!(canonical)
        @canonical_by_alias[alternate] = canonical
      end
    end

    def self.empty : self
      new
    end

    def canonical_for(alternate : String) : String?
      @canonical_by_alias[alternate]?
    end

    def pairs : Hash(String, String)
      @canonical_by_alias.dup
    end

    def merge(other : ReferenceAliases) : ReferenceAliases
      merged = pairs
      other.pairs.each do |alternate, canonical|
        if previous = merged[alternate]?
          if previous != canonical
            raise ReferenceValidationError.new("Alias #{alternate.inspect} maps to both #{previous.inspect} and #{canonical.inspect}")
          end
        else
          merged[alternate] = canonical
        end
      end
      ReferenceAliases.new(merged)
    end

    def validate_against!(dictionary : ContigDictionary) : Nil
      @canonical_by_alias.each_value do |canonical|
        unless dictionary.includes?(canonical)
          raise ReferenceValidationError.new("Alias target is not a reference contig: #{canonical.inspect}")
        end
      end
    end

    # IGV alias files can contain several naming systems per line.  A line is
    # accepted only when exactly one item is a canonical reference contig;
    # otherwise the line would make automatic mapping ambiguous.
    def self.from_igv_file(path : String, dictionary : ContigDictionary) : self
      checked = ReferenceFiles.local_file(path, "alias file")
      pairs = {} of String => String
      File.open(checked) do |file|
        ReferenceFiles.each_bounded_line(file, "Alias file") do |line, line_number|
          row = line.chomp
          next if row.empty? || row.starts_with?('#')
          names = row.split('\t')
          if names.size < 2 || names.any?(&.empty?)
            raise ReferenceValidationError.new("Alias file line #{line_number} must contain at least two tab-separated names")
          end
          names.each { |name| ContigDictionary.validate_name!(name) }
          canonical_names = names.select { |name| dictionary.includes?(name) }.uniq!
          next if canonical_names.empty?
          if canonical_names.size != 1
            raise ReferenceValidationError.new("Alias file line #{line_number} names multiple reference contigs: #{canonical_names.join(", ")}")
          end
          canonical = canonical_names.first
          names.each do |alternate|
            if previous = pairs[alternate]?
              if previous != canonical
                raise ReferenceValidationError.new("Alias #{alternate.inspect} maps to both #{previous.inspect} and #{canonical.inspect}")
              end
            else
              pairs[alternate] = canonical
            end
          end
        end
      end
      new(pairs)
    rescue ex : ReferenceValidationError
      raise ex
    rescue ex
      raise ReferenceValidationError.new("Could not read alias file #{path}: #{ex.message || ex.class.name}")
    end
  end

  enum ReferenceResourceKind
    Fasta
    Fai
    Alias
    Cytoband
    ChromSizes
  end

  # A resource is deliberately not serialised with its local path/content.
  # Servers use those accessors to register an allow-listed route; API clients
  # only receive `id`, kind and range requirements through #to_json.
  class ReferenceResource
    # IGV.js loads each of these auxiliary files as a complete response. Keep
    # those responses bounded, while allowing fragmented assemblies whose FAI
    # legitimately exceeds the generic 8 MiB file-response limit.
    MAX_FAI_FULL_RESPONSE_BYTES         = 64_i64 * 1024 * 1024
    MAX_ALIAS_FULL_RESPONSE_BYTES       = 16_i64 * 1024 * 1024
    MAX_CYTOBAND_FULL_RESPONSE_BYTES    = 32_i64 * 1024 * 1024
    MAX_CHROM_SIZES_FULL_RESPONSE_BYTES = 32_i64 * 1024 * 1024

    getter id : String
    getter kind : ReferenceResourceKind
    getter path : String?
    getter content : String?
    getter? range_required : Bool

    def initialize(@id : String, @kind : ReferenceResourceKind, @path : String? = nil, @content : String? = nil, @range_required : Bool = false)
      raise ReferenceValidationError.new("Reference resource id is empty") if @id.empty?
      if @path.nil? == @content.nil?
        raise ReferenceValidationError.new("Reference resource #{@id.inspect} must have exactly one source")
      end
    end

    def local_file? : Bool
      !@path.nil?
    end

    def generated? : Bool
      !@content.nil?
    end

    def content_type : String
      case @kind
      when .fasta?       then "text/plain; charset=utf-8"
      when .fai?         then "text/plain; charset=utf-8"
      when .alias?       then "text/plain; charset=utf-8"
      when .cytoband?    then "text/plain; charset=utf-8"
      when .chrom_sizes? then "text/plain; charset=utf-8"
      else
        raise ReferenceValidationError.new("Unsupported reference resource kind")
      end
    end

    # IGV reads FASTA sequence data by byte range, but its FAI, alias,
    # cytoband, and chrom.sizes loaders fetch complete files. This explicit
    # per-kind limit is passed to RangeFileHandler when the resource is served.
    def max_full_response_bytes : Int64
      return 0_i64 if @range_required

      case @kind
      when .fasta?       then 0_i64
      when .fai?         then MAX_FAI_FULL_RESPONSE_BYTES
      when .alias?       then MAX_ALIAS_FULL_RESPONSE_BYTES
      when .cytoband?    then MAX_CYTOBAND_FULL_RESPONSE_BYTES
      when .chrom_sizes? then MAX_CHROM_SIZES_FULL_RESPONSE_BYTES
      else
        raise ReferenceValidationError.new("Unsupported reference resource kind")
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", @id
        json.field "kind", @kind.to_s.underscore
        json.field "rangeRequired", @range_required
        json.field "generated", generated?
      end
    end
  end

  enum ReferenceKind
    Preset
    Fasta
    IgvJson
    ContigsOnly
  end

  # Registry data stays injectable so the curated browser definitions can be
  # updated in one place without changing reference parsing code. The built-in
  # registry intentionally carries no guessed contig dictionary: compatibility
  # remains Unverified until a real dictionary is supplied.
  class PresetRegistry
    # A deliberately small, auditable subset of an IGV public genome entry.
    # `connect_origins` is emitted into the local viewer's CSP, so every remote
    # resource is validated against it.
    class BrowserDefinition
      getter two_bit_url : String
      getter chrom_sizes_url : String
      getter? whole_genome_view : Bool

      @connect_origins : Array(String)
      @gene_track_url : String?
      @gene_track_name : String

      def initialize(@two_bit_url : String, @chrom_sizes_url : String, connect_origins : Array(String),
                     @whole_genome_view : Bool = true, @gene_track_url : String? = nil,
                     @gene_track_name : String = "Genes")
        validate_https_url!(@two_bit_url, "twoBitURL")
        validate_https_url!(@chrom_sizes_url, "chromSizesURL")
        @connect_origins = connect_origins.uniq
        raise ReferenceValidationError.new("Preset browser definition needs an HTTPS origin") if @connect_origins.empty?
        @connect_origins.each { |origin| validate_origin!(origin) }
        validate_resource_origin!(@two_bit_url, "twoBitURL")
        validate_resource_origin!(@chrom_sizes_url, "chromSizesURL")
        if url = @gene_track_url
          validate_https_url!(url, "gene track URL")
          validate_resource_origin!(url, "gene track URL")
          raise ReferenceValidationError.new("Preset gene track name is empty") if @gene_track_name.strip.empty?
        end
      end

      def connect_origins : Array(String)
        @connect_origins.dup
      end

      def write_igv_definition(json : JSON::Builder, id : String, name : String) : Nil
        json.object do
          json.field "id", id
          json.field "name", name
          json.field "twoBitURL", @two_bit_url
          json.field "chromSizesURL", @chrom_sizes_url
          json.field "wholeGenomeView", @whole_genome_view
          if url = @gene_track_url
            json.field "tracks" do
              json.array do
                json.object do
                  json.field "name", @gene_track_name
                  json.field "type", "annotation"
                  json.field "format", "bigbed"
                  json.field "url", url
                  json.field "displayMode", "COLLAPSED"
                end
              end
            end
          end
        end
      end

      private def validate_https_url!(url : String, key : String) : Nil
        if url.empty? || url.includes?('\0') || /\s/.matches?(url) || !url.starts_with?("https://")
          raise ReferenceValidationError.new("Preset #{key} must be an HTTPS URL")
        end
      end

      private def validate_origin!(origin : String) : Nil
        unless /\Ahttps:\/\/[A-Za-z0-9.-]+(?::[0-9]{1,5})?\z/.matches?(origin)
          raise ReferenceValidationError.new("Invalid preset connect origin: #{origin.inspect}")
        end
      end

      # A resource that is absent from connect-src would fail only after IGV
      # has opened the browser. Catch registry/CSP drift at construction time.
      private def validate_resource_origin!(url : String, key : String) : Nil
        match = /\A(https:\/\/[A-Za-z0-9.-]+(?::[0-9]{1,5})?)(?:[\/?#]|\z)/.match(url)
        origin = match.try(&.[1])
        unless origin && @connect_origins.includes?(origin)
          raise ReferenceValidationError.new("Preset #{key} origin is not allowed by connect-src")
        end
      end
    end

    class Definition
      getter id : String
      getter name : String
      getter dictionary : ContigDictionary?
      getter aliases : ReferenceAliases
      getter revision : String?
      getter browser : BrowserDefinition

      def initialize(@id : String, @browser : BrowserDefinition, name : String? = nil, @dictionary : ContigDictionary? = nil,
                     @aliases : ReferenceAliases = ReferenceAliases.empty, @revision : String? = nil)
        @name = name || @id
        ReferenceFiles.preset_id!(@id)
        raise ReferenceValidationError.new("Preset name is empty") if @name.strip.empty?
        if dictionary = @dictionary
          @aliases.validate_against!(dictionary)
        end
      end
    end

    @definitions : Hash(String, Definition)

    def initialize(definitions : Enumerable(Definition) = [] of Definition)
      @definitions = {} of String => Definition
      definitions.each { |definition| register(definition) }
    end

    def register(definition : Definition) : Nil
      raise ReferenceValidationError.new("Duplicate preset id: #{definition.id}") if @definitions.has_key?(definition.id)
      @definitions[definition.id] = definition
    end

    def fetch(id : String) : Definition
      @definitions[id]? || raise ReferenceValidationError.new("Unknown IGV preset genome: #{id.inspect}")
    end

    def self.default : self
      ucsc = ["https://hgdownload.soe.ucsc.edu"]
      new([
        Definition.new("hg38", BrowserDefinition.new(
          "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.2bit",
          "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.chrom.sizes", ucsc,
          gene_track_url: "https://hgdownload.soe.ucsc.edu/gbdb/hg38/gencode/gencodeV50.bb",
          gene_track_name: "GENCODE v50 genes")),
        Definition.new("hg19", BrowserDefinition.new(
          "https://hgdownload.soe.ucsc.edu/goldenPath/hg19/bigZips/hg19.2bit",
          "https://hgdownload.soe.ucsc.edu/goldenPath/hg19/bigZips/hg19.chrom.sizes", ucsc,
          gene_track_url: "https://hgdownload.soe.ucsc.edu/gbdb/hg19/gencode/gencodeV49lift37.bb",
          gene_track_name: "GENCODE v49lift37 genes")),
        Definition.new("hs1", BrowserDefinition.new(
          "https://hgdownload.soe.ucsc.edu/goldenPath/hs1/bigZips/hs1.2bit",
          "https://hgdownload.soe.ucsc.edu/goldenPath/hs1/bigZips/hs1.chrom.sizes.txt", ucsc,
          gene_track_url: "https://hgdownload.soe.ucsc.edu/gbdb/hs1/bbi/ncbiRefSeq.bb",
          gene_track_name: "NCBI RefSeq genes")),
        Definition.new("mm39", BrowserDefinition.new(
          "https://hgdownload.soe.ucsc.edu/goldenPath/mm39/bigZips/mm39.2bit",
          "https://hgdownload.soe.ucsc.edu/goldenPath/mm39/bigZips/mm39.chrom.sizes", ucsc,
          gene_track_url: "https://hgdownload.soe.ucsc.edu/gbdb/mm39/gencode/gencodeVM39.bb",
          gene_track_name: "GENCODE VM39 genes")),
      ])
    end
  end

  # A user-facing reference choice.  `aliases` always maps alternate name to
  # canonical reference name.  File checks occur at #resolve so CLI/UI code can
  # construct an option before it decides when to validate it.
  class ReferenceSpec
    getter kind : ReferenceKind
    getter aliases : ReferenceAliases

    @preset_id : String?
    @fasta_path : String?
    @fai_path : String?
    @json_path : String?
    @contigs : ContigDictionary?
    @id : String?
    @name : String?

    private def initialize(@kind : ReferenceKind, @aliases : ReferenceAliases,
                           @preset_id : String? = nil, @fasta_path : String? = nil,
                           @fai_path : String? = nil, @json_path : String? = nil,
                           @contigs : ContigDictionary? = nil, @id : String? = nil,
                           @name : String? = nil)
    end

    def self.preset(id : String) : self
      ReferenceFiles.preset_id!(id)
      new(ReferenceKind::Preset, ReferenceAliases.empty, preset_id: id)
    end

    def self.fasta(path : String, fai_path : String? = nil, id : String? = nil, name : String? = nil,
                   aliases : Hash(String, String) = {} of String => String) : self
      new(ReferenceKind::Fasta, ReferenceAliases.new(aliases), fasta_path: path, fai_path: fai_path, id: id, name: name)
    end

    def self.igv_json(path : String, aliases : Hash(String, String) = {} of String => String) : self
      new(ReferenceKind::IgvJson, ReferenceAliases.new(aliases), json_path: path)
    end

    def self.contigs_only(contigs : ContigDictionary, id : String = "contigs-only", name : String = "Contigs only") : self
      new(ReferenceKind::ContigsOnly, ReferenceAliases.empty, contigs: contigs, id: id, name: name)
    end

    def self.contigs_only(contigs : Hash(String, UInt32), id : String = "contigs-only", name : String = "Contigs only") : self
      contigs_only(ContigDictionary.from_hash(contigs), id, name)
    end

    def resolve(registry : PresetRegistry = PresetRegistry.default) : ResolvedReference
      case @kind
      when .preset?
        definition = registry.fetch(@preset_id || (raise ReferenceValidationError.new("Preset id is unavailable")))
        ResolvedReference.preset(definition)
      when .fasta?
        ResolvedReference.from_fasta(@fasta_path || (raise ReferenceValidationError.new("FASTA path is unavailable")), @fai_path, @id, @name, @aliases)
      when .igv_json?
        ResolvedReference.from_igv_json(@json_path || (raise ReferenceValidationError.new("IGV JSON path is unavailable")), @aliases)
      when .contigs_only?
        ResolvedReference.contigs_only(@contigs || (raise ReferenceValidationError.new("Contig dictionary is unavailable")), @id || (raise ReferenceValidationError.new("Reference id is unavailable")), @name || (raise ReferenceValidationError.new("Reference name is unavailable")))
      else
        raise ReferenceValidationError.new("Unsupported reference kind")
      end
    end
  end

  enum CompatibilityStatus
    Compatible
    Partial
    Incompatible
    Unverified
  end

  enum ContigMatchKind
    Exact
    ExplicitAlias
    ConservativeAlias
  end

  record ContigMatch, reference_name : String, track_name : String, length : Int64, kind : ContigMatchKind
  record LengthMismatch, reference_name : String, track_name : String, reference_length : Int64, track_length : Int64, kind : ContigMatchKind
  record AmbiguousContig, reference_name : String, candidates : Array(String), kind : ContigMatchKind

  class ReferenceCompatibility
    getter status : CompatibilityStatus
    getter matches : Array(ContigMatch)
    getter missing_reference_contigs : Array(String)
    getter unmapped_track_contigs : Array(String)
    getter length_mismatches : Array(LengthMismatch)
    getter ambiguous_contigs : Array(AmbiguousContig)

    def initialize(@status : CompatibilityStatus, @matches : Array(ContigMatch) = [] of ContigMatch,
                   @missing_reference_contigs : Array(String) = [] of String,
                   @unmapped_track_contigs : Array(String) = [] of String,
                   @length_mismatches : Array(LengthMismatch) = [] of LengthMismatch,
                   @ambiguous_contigs : Array(AmbiguousContig) = [] of AmbiguousContig)
    end

    def compatible? : Bool
      @status.compatible?
    end

    def partial? : Bool
      @status.partial?
    end

    def incompatible? : Bool
      @status.incompatible?
    end

    def unverified? : Bool
      @status.unverified?
    end

    def track_name_for(reference_name : String) : String?
      @matches.find { |match| match.reference_name == reference_name }.try(&.track_name)
    end

    def reference_name_for(track_name : String) : String?
      @matches.find { |match| match.track_name == track_name }.try(&.reference_name)
    end
  end

  # A validated reference plus only the resources the local server may expose.
  # It has no general "serve this path" API.
  class ResolvedReference
    getter kind : ReferenceKind
    getter id : String
    getter name : String
    getter dictionary : ContigDictionary?
    getter aliases : ReferenceAliases
    getter resources : Array(ReferenceResource)
    getter preset_id : String?
    getter source_path : String?

    @whole_genome_view : Bool
    @preset_browser : PresetRegistry::BrowserDefinition?

    private def initialize(@kind : ReferenceKind, @id : String, @name : String,
                           @dictionary : ContigDictionary?, @aliases : ReferenceAliases,
                           @resources : Array(ReferenceResource), @preset_id : String? = nil,
                           @source_path : String? = nil, @whole_genome_view : Bool = true,
                           @preset_browser : PresetRegistry::BrowserDefinition? = nil)
    end

    def self.preset(definition : PresetRegistry::Definition) : self
      new(ReferenceKind::Preset, definition.id, definition.name, definition.dictionary,
        definition.aliases, [] of ReferenceResource, preset_id: definition.id, preset_browser: definition.browser)
    end

    def self.from_fasta(path : String, explicit_fai : String?, id : String?, name : String?, explicit_aliases : ReferenceAliases) : self
      fasta, fai, index = ReferenceFiles.resolve_fasta(path, explicit_fai)
      explicit_aliases.validate_against!(index.dictionary)
      reference_id = ReferenceFiles.reference_id(id || File.basename(fasta, File.extname(fasta)))
      reference_name = ReferenceFiles.reference_name(name || reference_id)
      resources = [
        ReferenceResource.new("fasta", ReferenceResourceKind::Fasta, path: fasta, range_required: true),
        ReferenceResource.new("fai", ReferenceResourceKind::Fai, path: fai),
      ]
      new(ReferenceKind::Fasta, reference_id, reference_name, index.dictionary, explicit_aliases, resources, source_path: fasta)
    end

    def self.from_igv_json(path : String, explicit_aliases : ReferenceAliases) : self
      json_path = ReferenceFiles.local_file(path, "IGV genome JSON")
      root = ReferenceFiles.read_genome_json(json_path)
      ReferenceFiles.validate_genome_json_keys!(root)

      fasta_value = ReferenceFiles.required_json_string(root, "fastaURL", json_path)
      index_value = ReferenceFiles.optional_json_string(root, "indexURL", json_path)
      fasta_input = ReferenceFiles.resolve_json_path(fasta_value, json_path, "fastaURL")
      fai_input = index_value.try { |value| ReferenceFiles.resolve_json_path(value, json_path, "indexURL") }
      fasta, fai, index = ReferenceFiles.resolve_fasta(fasta_input, fai_input)

      json_aliases = if alias_value = ReferenceFiles.optional_json_string(root, "aliasURL", json_path)
                       alias_path = ReferenceFiles.resolve_json_path(alias_value, json_path, "aliasURL")
                       ReferenceAliases.from_igv_file(alias_path, index.dictionary)
                     else
                       ReferenceAliases.empty
                     end
      aliases = json_aliases.merge(explicit_aliases)
      aliases.validate_against!(index.dictionary)

      chrom_sizes_path = ReferenceFiles.optional_json_string(root, "chromSizesURL", json_path).try do |value|
        ReferenceFiles.resolve_json_path(value, json_path, "chromSizesURL")
      end
      if chrom_sizes_path
        sizes = ContigDictionary.from_chrom_sizes(chrom_sizes_path)
        ReferenceFiles.require_same_dictionary!(index.dictionary, sizes, "FAI", "chromSizesURL")
      end
      cytoband_path = ReferenceFiles.optional_json_string(root, "cytobandURL", json_path).try do |value|
        ReferenceFiles.resolve_json_path(value, json_path, "cytobandURL")
      end

      id = ReferenceFiles.reference_id(ReferenceFiles.optional_json_string(root, "id", json_path) || File.basename(json_path, File.extname(json_path)))
      name = ReferenceFiles.reference_name(ReferenceFiles.optional_json_string(root, "name", json_path) || id)
      whole_genome_view = ReferenceFiles.optional_json_bool(root, "wholeGenomeView", json_path) || false
      resources = [
        ReferenceResource.new("fasta", ReferenceResourceKind::Fasta, path: fasta, range_required: true),
        ReferenceResource.new("fai", ReferenceResourceKind::Fai, path: fai),
      ]
      if alias_value = ReferenceFiles.optional_json_string(root, "aliasURL", json_path)
        resources << ReferenceResource.new("aliases", ReferenceResourceKind::Alias,
          path: ReferenceFiles.resolve_json_path(alias_value, json_path, "aliasURL"))
      end
      if cytoband_path
        resources << ReferenceResource.new("cytobands", ReferenceResourceKind::Cytoband, path: cytoband_path)
      end
      if chrom_sizes_path
        resources << ReferenceResource.new("chrom-sizes", ReferenceResourceKind::ChromSizes, path: chrom_sizes_path)
      end
      new(ReferenceKind::IgvJson, id, name, index.dictionary, aliases, resources, source_path: json_path,
        whole_genome_view: whole_genome_view)
    end

    def self.contigs_only(dictionary : ContigDictionary, id : String, name : String) : self
      checked_id = ReferenceFiles.reference_id(id)
      checked_name = ReferenceFiles.reference_name(name)
      resource = ReferenceResource.new("chrom-sizes", ReferenceResourceKind::ChromSizes,
        content: dictionary.chrom_sizes_text)
      new(ReferenceKind::ContigsOnly, checked_id, checked_name, dictionary, ReferenceAliases.empty,
        [resource], whole_genome_view: false)
    end

    def resource(id : String) : ReferenceResource?
      @resources.find { |item| item.id == id }
    end

    # Local FASTA/JSON and contigs-only references have no browser-external
    # fetches. Presets use their curated, allow-listed twoBit resources.
    def browser_connect_origins : Array(String)
      @preset_browser.try(&.connect_origins) || [] of String
    end

    # Config for igv.createBrowser.  The caller must first register every
    # descriptor in #resources and pass route URLs keyed by descriptor id.  This
    # prevents local filesystem paths from accidentally reaching browser JSON.
    def igv_browser_config_json(resource_urls : Hash(String, String) = {} of String => String) : String
      JSON.build do |json|
        json.object do
          # Otherwise IGV.js always tries its global genome registry before
          # opening even a wholly local FASTA, causing an unnecessary external
          # request (and a multi-second fallback delay under a strict CSP).
          json.field "loadDefaultGenomes", false
          if @kind.preset?
            browser = @preset_browser || raise ReferenceValidationError.new("Preset browser definition is unavailable")
            json.field "genomeList" do
              json.array { browser.write_igv_definition(json, @id, @name) }
            end
            json.field("genome", @preset_id || raise ReferenceValidationError.new("Preset id is unavailable"))
          else
            json.field "reference" do
              write_igv_reference(json, resource_urls)
            end
          end
        end
      end
    end

    def igv_browser_config(resource_urls : Hash(String, String) = {} of String => String) : JSON::Any
      JSON.parse(igv_browser_config_json(resource_urls))
    end

    # Exact, explicit-alias, and conservative-alias matching intentionally use
    # separate branches so unsafe implicit mappings cannot be introduced.
    # ameba:disable Metrics/CyclomaticComplexity
    def compatibility_with(track : ContigDictionary) : ReferenceCompatibility
      reference = @dictionary
      return ReferenceCompatibility.new(CompatibilityStatus::Unverified, unmapped_track_contigs: track.entries.map(&.name)) unless reference

      matches = [] of ContigMatch
      missing = [] of String
      mismatches = [] of LengthMismatch
      ambiguous = [] of AmbiguousContig
      used = {} of String => Bool

      reference.entries.each do |ref|
        if track_length = track[ref.name]
          if track_length == ref.length
            matches << ContigMatch.new(ref.name, ref.name, ref.length, ContigMatchKind::Exact)
            used[ref.name] = true
          else
            mismatches << LengthMismatch.new(ref.name, ref.name, ref.length, track_length, ContigMatchKind::Exact)
          end
          next
        end

        explicit = track.entries.select { |entry| !used.has_key?(entry.name) && @aliases.canonical_for(entry.name) == ref.name }
        if resolve_candidates(ref, explicit, ContigMatchKind::ExplicitAlias, matches, mismatches, ambiguous, used)
          next
        end

        candidates = conservative_candidates(ref.name).compact_map do |candidate|
          length = track[candidate]
          length && !used.has_key?(candidate) ? Contig.new(candidate, length) : nil
        end
        if resolve_candidates(ref, candidates, ContigMatchKind::ConservativeAlias, matches, mismatches, ambiguous, used)
          next
        end
        missing << ref.name
      end

      unmapped = track.entries.reject { |entry| used.has_key?(entry.name) }.map(&.name)
      status = if mismatches.present? || ambiguous.present?
                 CompatibilityStatus::Incompatible
               elsif matches.empty?
                 CompatibilityStatus::Incompatible
               elsif missing.empty? && unmapped.empty?
                 CompatibilityStatus::Compatible
               else
                 CompatibilityStatus::Partial
               end
      ReferenceCompatibility.new(status, matches, missing, unmapped, mismatches, ambiguous)
    end

    def compatibility_with(track : Hash(String, UInt32)) : ReferenceCompatibility
      compatibility_with(ContigDictionary.from_hash(track))
    end

    private def write_igv_reference(json : JSON::Builder, resource_urls : Hash(String, String)) : Nil
      json.object do
        json.field "id", @id
        json.field "name", @name
        if @kind.contigs_only?
          json.field "format", "chromsizes"
          json.field "fastaURL", url_for!("chrom-sizes", resource_urls)
          json.field "wholeGenomeView", false
        else
          json.field "fastaURL", url_for!("fasta", resource_urls)
          json.field "indexURL", url_for!("fai", resource_urls)
          json.field "aliasURL", url_for!("aliases", resource_urls) if resource("aliases")
          json.field "cytobandURL", url_for!("cytobands", resource_urls) if resource("cytobands")
          json.field "chromSizesURL", url_for!("chrom-sizes", resource_urls) if resource("chrom-sizes")
          json.field "wholeGenomeView", @whole_genome_view
        end
      end
    end

    private def url_for!(id : String, resource_urls : Hash(String, String)) : String
      resource = resource(id) || raise ReferenceValidationError.new("Unknown reference resource: #{id}")
      url = resource_urls[id]? || raise ReferenceValidationError.new("No browser URL registered for reference resource: #{id}")
      if url.empty? || url.includes?('\0') || url.starts_with?("file:") || resource.path == url
        raise ReferenceValidationError.new("Unsafe browser URL for reference resource: #{id}")
      end
      url
    end

    private def resolve_candidates(ref : Contig, candidates : Array(Contig), kind : ContigMatchKind,
                                   matches : Array(ContigMatch), mismatches : Array(LengthMismatch),
                                   ambiguous : Array(AmbiguousContig), used : Hash(String, Bool)) : Bool
      return false if candidates.empty?
      if candidates.size > 1
        ambiguous << AmbiguousContig.new(ref.name, candidates.map(&.name), kind)
        return true
      end
      candidate = candidates.first
      if candidate.length == ref.length
        matches << ContigMatch.new(ref.name, candidate.name, ref.length, kind)
        used[candidate.name] = true
      else
        mismatches << LengthMismatch.new(ref.name, candidate.name, ref.length, candidate.length, kind)
      end
      true
    end

    # Only conventional autosomes/X/Y and mitochondrial spelling are inferred.
    # We never apply a general `chr` prefix/suffix rewrite to arbitrary contigs.
    private def conservative_candidates(name : String) : Array(String)
      values = [] of String
      if match = /\Achr([1-9][0-9]*|X|Y)\z/.match(name)
        values << match[1]
      elsif /\A(?:[1-9][0-9]*|X|Y)\z/.matches?(name)
        values << "chr#{name}"
      end
      case name
      when "MT", "M", "chrM", "chrMT"
        values.concat(["MT", "M", "chrM", "chrMT"])
        values.delete(name)
      end
      values.uniq
    end
  end

  # File/path/JSON primitives are private implementation detail but live in a
  # module to keep ReferenceSpec and ResolvedReference small and testable.
  module ReferenceFiles
    MAX_GENOME_JSON_BYTES = 1 * 1024 * 1024

    # IO#each_line allocates a complete line before yielding it. These files
    # are user supplied, so cap the allocation itself instead of checking a
    # line only after an arbitrarily long string has already been created.
    def self.each_bounded_line(file : IO, label : String, & : String, Int32 ->) : Nil
      line_number = 0
      while line = file.gets(FaiIndex::MAX_LINE_BYTES + 1, chomp: false)
        line_number += 1
        if line.bytesize > FaiIndex::MAX_LINE_BYTES
          raise ReferenceValidationError.new("#{label} line #{line_number} is too long")
        end
        yield line, line_number
      end
    end

    def self.local_file(path : String, label : String) : String
      if path.strip.empty? || path.includes?('\0')
        raise ReferenceValidationError.new("#{label} path is empty or invalid")
      end
      expanded = File.expand_path(path)
      real = File.realpath(expanded)
      unless File.file?(real)
        raise ReferenceValidationError.new("#{label} is not a regular file: #{path}")
      end
      File.open(real, "rb") { }
      real
    rescue ex : ReferenceValidationError
      raise ex
    rescue ex
      raise ReferenceValidationError.new("Could not access #{label} #{path.inspect}: #{ex.message || ex.class.name}")
    end

    def self.resolve_fasta(path : String, explicit_fai : String?) : Tuple(String, String, FaiIndex)
      fasta = local_file(path, "FASTA")
      validate_plain_fasta!(fasta)
      fai_input = explicit_fai || "#{path}.fai"
      fai = local_file(fai_input, "FAI")
      index = FaiIndex.read(fai)
      index.validate_for_fasta!(fasta)
      {fasta, fai, index}
    end

    def self.validate_plain_fasta!(path : String) : Nil
      lower = path.downcase
      if lower.ends_with?(".gz") || lower.ends_with?(".bgz") || lower.ends_with?(".bgzf")
        raise ReferenceValidationError.new("Compressed FASTA is not supported without an explicit BGZF/GZI implementation: #{path}")
      end
      File.open(path, "rb") do |fasta|
        first = fasta.read_byte
        second = fasta.read_byte
        if first != '>'.ord || (first == 0x1f && second == 0x8b)
          raise ReferenceValidationError.new("FASTA does not begin with a header: #{path}")
        end
      end
    end

    def self.unsigned_length!(text : String, label : String) : Int64
      value = positive_int64!(text, label)
      ContigDictionary.validate_length!(value, label)
      value
    end

    def self.positive_int64!(text : String, label : String) : Int64
      unless /\A[1-9][0-9]*\z/.matches?(text)
        raise ReferenceValidationError.new("#{label} must be a positive decimal integer")
      end
      text.to_i64? || raise ReferenceValidationError.new("#{label} is outside Int64 range")
    end

    def self.non_negative_int64!(text : String, label : String) : Int64
      unless /\A(?:0|[1-9][0-9]*)\z/.matches?(text)
        raise ReferenceValidationError.new("#{label} must be a non-negative decimal integer")
      end
      text.to_i64? || raise ReferenceValidationError.new("#{label} is outside Int64 range")
    end

    def self.preset_id!(id : String) : Nil
      unless /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.matches?(id)
        raise ReferenceValidationError.new("Invalid preset genome id: #{id.inspect}")
      end
    end

    def self.reference_id(value : String) : String
      preset_id!(value)
      value
    end

    def self.reference_name(value : String) : String
      if value.strip.empty? || value.includes?('\0') || value.bytesize > 1_024
        raise ReferenceValidationError.new("Invalid reference name")
      end
      value
    end

    def self.read_genome_json(path : String) : Hash(String, JSON::Any)
      if File.size(path) > MAX_GENOME_JSON_BYTES
        raise ReferenceValidationError.new("IGV genome JSON is too large: #{path}")
      end
      JSON.parse(File.read(path)).as_h
    rescue ex : ReferenceValidationError
      raise ex
    rescue ex
      raise ReferenceValidationError.new("Invalid IGV genome JSON #{path}: #{ex.message || ex.class.name}")
    end

    def self.validate_genome_json_keys!(root : Hash(String, JSON::Any)) : Nil
      allowed = ["id", "name", "fastaURL", "indexURL", "aliasURL", "cytobandURL", "chromSizesURL", "format", "wholeGenomeView"]
      root.each_key do |key|
        unless allowed.includes?(key)
          raise ReferenceValidationError.new("Unsupported IGV genome JSON key: #{key}")
        end
      end
      if format = optional_json_string(root, "format", "IGV genome JSON")
        unless format.downcase == "fasta"
          raise ReferenceValidationError.new("Unsupported IGV genome JSON format: #{format.inspect}")
        end
      end
    end

    def self.required_json_string(root : Hash(String, JSON::Any), key : String, source : String) : String
      optional_json_string(root, key, source) || raise ReferenceValidationError.new("IGV genome JSON #{source} is missing #{key}")
    end

    def self.optional_json_string(root : Hash(String, JSON::Any), key : String, source : String) : String?
      value = root[key]?
      return unless value
      text = value.as_s?
      if text.nil? || text.empty? || text.includes?('\0')
        raise ReferenceValidationError.new("IGV genome JSON #{source} has invalid #{key}")
      end
      text
    end

    def self.optional_json_bool(root : Hash(String, JSON::Any), key : String, source : String) : Bool?
      value = root[key]?
      return unless value
      value.as_bool? || raise ReferenceValidationError.new("IGV genome JSON #{source} has invalid #{key}")
    end

    # The initial local implementation intentionally rejects remote/data/file
    # URLs.  A future URL fetcher can be added here with its own Range/CORS and
    # origin policy rather than accidentally making JSON parsing a network API.
    def self.resolve_json_path(value : String, json_path : String, key : String) : String
      if windows_unc_path?(value) || (!windows_drive_path?(value) && /\A[A-Za-z][A-Za-z0-9+.-]*:/.matches?(value)) || value.starts_with?("//")
        raise ReferenceValidationError.new("IGV genome JSON #{key} must be a local path, not a URL")
      end
      base = File.dirname(json_path)
      local_file(File.expand_path(value, base), "IGV genome JSON #{key}")
    end

    # `C:\\reference\\genome.fa` is a local absolute path on Windows, not a
    # URI with scheme `c`. Keep the URL rejection strict on other platforms.
    private def self.windows_drive_path?(value : String) : Bool
      {% if flag?(:win32) %}
        /\A[A-Za-z]:[\\\/]/.matches?(value)
      {% else %}
        false
      {% end %}
    end

    # A UNC path is a network location on Windows. Reject it on every platform
    # so a genome JSON remains strictly local even if it is later shared with a
    # Windows installation.
    private def self.windows_unc_path?(value : String) : Bool
      value.starts_with?("\\\\")
    end

    def self.require_same_dictionary!(left : ContigDictionary, right : ContigDictionary, left_name : String, right_name : String) : Nil
      unless left.entries == right.entries
        raise ReferenceValidationError.new("#{left_name} and #{right_name} describe different contig dictionaries")
      end
    end
  end
end
