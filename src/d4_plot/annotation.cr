require "compress/gzip"
require "hts/tabix"
require "./region"

module D4Plot
  class AnnotationCancelled < Exception; end

  struct AnnotationFeature
    getter chromosome : String
    getter start1 : UInt32
    getter end1 : UInt32
    getter kind : String
    getter name : String?
    getter strand : String?

    def initialize(@chromosome : String, @start1 : UInt32, @end1 : UInt32, @kind : String, @name : String?, @strand : String?); end
  end

  class AnnotationTrack
    getter features : Array(AnnotationFeature)
    getter notice : String?

    def initialize(@features : Array(AnnotationFeature), @notice : String? = nil); end

    def_equals_and_hash features, notice

    def self.features(features : Array(AnnotationFeature))
      new(features)
    end

    def self.notice(message : String)
      new([] of AnnotationFeature, message)
    end

    def self.too_many(limit : Int32)
      notice(D4Plot.t("annotation.too_many", limit: limit))
    end

    def empty?
      @features.empty? && @notice.nil?
    end
  end

  class AnnotationIndex
    FEATURE_TYPES          = {"gene", "transcript", "mrna", "exon"}
    MAX_IN_MEMORY_BYTES    = 32 * 1024 * 1024
    MAX_IN_MEMORY_FEATURES = 100_000
    # Annotation records are normally short. Bound one record independently
    # from the total input budget: IO#each_line otherwise allocates the whole
    # record before the aggregate memory check can reject a malformed file.
    MAX_IN_MEMORY_LINE_BYTES = 64 * 1024

    getter path : String
    getter size : Int32
    getter? indexed : Bool
    getter chromosome_names : Array(String)

    @cache_key : String?
    @cache_features : Array(AnnotationFeature)

    def initialize(@path : String, features : Array(AnnotationFeature), @indexed : Bool = false, chromosome_names : Array(String)? = nil)
      @cache_key = nil
      @cache_features = [] of AnnotationFeature
      @features_by_chromosome = Hash(String, Array(AnnotationFeature)).new { |hash, key| hash[key] = [] of AnnotationFeature }
      features.each do |feature|
        @features_by_chromosome[feature.chromosome] << feature
      end
      @features_by_chromosome.each_value(&.sort_by! { |feature| {feature.start1, feature.end1} })
      @size = features.size
      @chromosome_names = chromosome_names || @features_by_chromosome.keys
    end

    def self.indexed(path : String)
      names = HTS::Tabix.open(path, &.seqnames)
      new(path, [] of AnnotationFeature, indexed: true, chromosome_names: names)
    rescue ex : HTS::Error
      raise D4Plot.t("annotation.index_read_failed", error: ex.message || ex.class.name)
    end

    def self.load(path : String, cancelled : Proc(Bool)? = nil)
      raise AnnotationCancelled.new if cancelled.try(&.call)
      return indexed(path) if tabix_indexed?(path)
      validate_in_memory_size(path)

      features = [] of AnnotationFeature
      bytes = 0_i64
      lines = 0
      each_line(path) do |line|
        lines += 1
        raise AnnotationCancelled.new if lines % 1_024 == 0 && cancelled.try(&.call)
        bytes += line.bytesize + 1
        raise D4Plot.t("annotation.memory_limit") if bytes > MAX_IN_MEMORY_BYTES
        if feature = parse_line(line)
          raise D4Plot.t("annotation.memory_limit") if features.size >= MAX_IN_MEMORY_FEATURES
          features << feature
        end
      end
      raise AnnotationCancelled.new if cancelled.try(&.call)
      raise D4Plot.t("annotation.no_features") if features.empty?
      new(path, features)
    end

    def overlapping(region : Region, limit : Int32)
      return overlapping_with_tabix(region, limit) if indexed?

      features = features_for(region.chromosome)
      return [] of AnnotationFeature if features.empty?

      matches = [] of AnnotationFeature
      query_limit = limit + 1
      features.each do |feature|
        break if feature.start1 > region.end1
        next if feature.end1 < region.start1

        matches << feature
        break if matches.size >= query_limit
      end
      matches
    end

    def track_for(region : Region, max_region_size : UInt32, limit : Int32)
      unless @chromosome_names.includes?(region.chromosome)
        return AnnotationTrack.notice(D4Plot.t("annotation.chromosome_missing", chromosome: region.chromosome.inspect))
      end
      if region.length > max_region_size
        return AnnotationTrack.notice(D4Plot.t("annotation.zoom_in"))
      end

      features = overlapping(region, limit)
      return AnnotationTrack.too_many(limit) if features.size > limit
      return AnnotationTrack.notice(D4Plot.t("annotation.no_overlap")) if features.empty?

      AnnotationTrack.features(features)
    end

    def description
      indexed? ? D4Plot.t("annotation.indexed") : D4Plot.t("annotation.features", number: size)
    end

    private def features_for(chromosome)
      @features_by_chromosome[chromosome]? || [] of AnnotationFeature
    end

    private def overlapping_with_tabix(region, limit)
      key = "#{region.chromosome}:#{region.start1}-#{region.end1}:#{limit}"
      return @cache_features if @cache_key == key

      features = query_tabix_region(region.chromosome, region.start1, region.end1, limit)
      @cache_key = key
      @cache_features = features
      features
    end

    private def query_tabix_region(chromosome, start1, end1, limit)
      features = [] of AnnotationFeature
      query_limit = limit + 1
      # HTSlib expects 0-based, half-open coordinates. Block-scoped readers
      # release the file, index and iterator even on early exit or a read error.
      HTS::Tabix.open(@path) do |reader|
        reader.query(chromosome, start1.to_i64 - 1, end1.to_i64) do |fields|
          if feature = self.class.parse_fields(fields)
            features << feature
            break if features.size >= query_limit
          end
        end
      end
      features
    rescue ex : HTS::Error
      raise D4Plot.t("annotation.indexed_read_failed") + "\n#{ex.message || ex.class.name}"
    end

    private def self.tabix_indexed?(path)
      compressed_annotation?(path) && (File.exists?("#{path}.tbi") || File.exists?("#{path}.csi"))
    end

    private def self.validate_in_memory_size(path)
      size = File.size(path)
      return if size <= MAX_IN_MEMORY_BYTES

      raise D4Plot.t("annotation.file_too_large")
    end

    private def self.each_line(path, &)
      File.open(path) do |file|
        if compressed_annotation?(path)
          Compress::Gzip::Reader.open(file) do |gzip|
            each_bounded_line(gzip) { |line| yield line }
          end
        else
          each_bounded_line(file) { |line| yield line }
        end
      end
    end

    # BGZF uses the gzip container format, and commonly uses these suffixes.
    # Keep this in sync for both indexed and in-memory annotation loading.
    private def self.compressed_annotation?(path : String) : Bool
      normalized = path.downcase
      normalized.ends_with?(".gz") || normalized.ends_with?(".bgz") || normalized.ends_with?(".bgzf") || normalized.ends_with?(".bgzip")
    end

    private def self.each_bounded_line(io : IO, &) : Nil
      while line = io.gets(MAX_IN_MEMORY_LINE_BYTES + 1, chomp: true)
        raise D4Plot.t("annotation.memory_limit") if line.bytesize > MAX_IN_MEMORY_LINE_BYTES
        yield line
      end
    end

    def self.parse_line(line)
      return if line.empty? || line.starts_with?(/^(#|track |browser )/)

      parse_fields(line.split('\t'))
    end

    def self.parse_fields(fields : Array(String))
      if fields.size >= 3 && fields[1].to_u32? && fields[2].to_u32?
        return parse_bed(fields)
      end
      parse_gff(fields)
    end

    private def self.parse_gff(fields)
      return unless fields.size >= 9

      kind = fields[2].downcase
      return unless FEATURE_TYPES.includes?(kind)

      start1 = fields[3].to_u32?
      end1 = fields[4].to_u32?
      return unless start1 && end1 && start1 > 0 && end1 >= start1
      strand = fields[6]
      strand = nil unless strand == "+" || strand == "-"

      AnnotationFeature.new(
        fields[0],
        start1,
        end1,
        kind,
        feature_name(parse_attributes(fields[8])),
        strand
      )
    end

    private def self.parse_bed(fields)
      start0 = fields[1].to_u32
      end0 = fields[2].to_u32
      return if end0 <= start0
      strand = fields[5]?
      strand = nil unless strand == "+" || strand == "-"
      name = fields[3]?
      name = nil if name == "."
      AnnotationFeature.new(fields[0], start0 + 1, end0, "region", name, strand)
    end

    private def self.parse_attributes(text)
      attributes = Hash(String, String).new
      text.split(';').each do |part|
        parse_attribute(part.strip, attributes)
      end
      attributes
    end

    private def self.parse_attribute(part, attributes)
      return if part.empty?

      if key_value = part.split('=', 2)
        if key_value.size == 2
          attributes[key_value[0]] = key_value[1]
          return
        end
      end

      if match = part.match(/^(\S+)\s+"?([^"]+)"?$/)
        attributes[match[1]] = match[2]
      end
    end

    private def self.feature_name(attributes)
      attributes["Name"]? ||
        attributes["gene_name"]? ||
        attributes["gene"]? ||
        attributes["transcript_name"]? ||
        attributes["gene_id"]? ||
        attributes["transcript_id"]? ||
        attributes["ID"]? ||
        attributes["Parent"]?
    end
  end
end
