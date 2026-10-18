require "http/client"
require "json"
require "uri"
require "wait_group"
require "./annotation"

module D4Plot
  struct GeneModel
    getter chromosome : String
    getter start1 : UInt32
    getter end1 : UInt32
    getter name : String
    getter strand : String?
    getter exons : Array(Tuple(UInt32, UInt32))

    def initialize(@chromosome : String, @start1 : UInt32, @end1 : UInt32, @name : String,
                   @strand : String?, @exons : Array(Tuple(UInt32, UInt32))); end
  end

  struct GeneTrack
    getter genes : Array(GeneModel)
    getter notice : String?

    def initialize(@genes : Array(GeneModel), @notice : String? = nil); end

    def self.notice(message : String) : self
      new([] of GeneModel, message)
    end
  end

  module PublicGenes
    GENOMES            = {"hg38", "hg19", "hs1", "mm39"}
    SOURCES            = {"ucsc", "ensembl"}
    MAX_REGION_SIZE    = 5_000_000_u32
    MAX_RESPONSE_BYTES = 8 * 1024 * 1024

    def self.track_for(genome : String) : String
      raise ArgumentError.new("Unknown public genome: #{genome}") unless GENOMES.includes?(genome)
      genome == "hs1" ? "ncbiRefSeq" : "knownGene"
    end

    # The D4 header does not identify an assembly. Only conventional chromosome
    # spellings are mapped; arbitrary contigs are never silently rewritten.
    def self.remote_chromosome(name : String) : String?
      return name if /\Achr(?:[1-9][0-9]*|X|Y|M)\z/.matches?(name)
      return "chr#{name}" if /\A(?:[1-9][0-9]*|X|Y)\z/.matches?(name)
      return "chrM" if {"M", "MT", "chrMT"}.includes?(name)
      nil
    end

    def self.ensembl_chromosome(name : String) : String?
      chromosome = remote_chromosome(name)
      return unless chromosome
      chromosome == "chrM" ? "MT" : chromosome.lchop("chr")
    end

    def self.validate_source(source : String) : Nil
      raise ArgumentError.new("Unknown public annotation source: #{source}") unless SOURCES.includes?(source)
    end

    def self.path(genome : String, chromosome : String, region : Region, limit : Int32) : String
      params = URI::Params.encode({
        "genome"         => genome,
        "track"          => track_for(genome),
        "chrom"          => chromosome,
        "start"          => region.start0.to_s,
        "end"            => region.end1.to_s,
        "maxItemsOutput" => (limit + 1).to_s,
      })
      "/getData/track?#{params}"
    end

    def self.ensembl_host(genome : String) : String
      track_for(genome)
      raise ArgumentError.new("Ensembl has no supported hs1 interval gene endpoint") if genome == "hs1"
      genome == "hg19" ? "https://grch37.rest.ensembl.org" : "https://rest.ensembl.org"
    end

    def self.ensembl_path(genome : String, chromosome : String, region : Region) : String
      species = genome == "mm39" ? "mus_musculus" : "homo_sapiens"
      "/overlap/region/#{species}/#{chromosome}:#{region.start1}-#{region.end1}?feature=gene;feature=transcript;feature=exon;content-type=application/json"
    end

    def self.fetch(source : String, genome : String, chromosome : String, region : Region, limit : Int32) : String
      validate_source(source)
      host, request_path = if source == "ucsc"
                             {"https://api.genome.ucsc.edu", path(genome, chromosome, region, limit)}
                           else
                             {ensembl_host(genome), ensembl_path(genome, chromosome, region)}
                           end
      client = HTTP::Client.new(URI.parse(host))
      client.connect_timeout = 3.seconds
      client.read_timeout = 10.seconds
      client.exec("GET", request_path) do |response|
        raise "#{source == "ucsc" ? "UCSC" : "Ensembl"} API returned HTTP #{response.status_code}" unless response.success?
        buffer = IO::Memory.new
        chunk = Bytes.new(16 * 1024)
        while (count = response.body_io.read(chunk)) > 0
          raise "Public annotation response is too large" if buffer.size + count > MAX_RESPONSE_BYTES
          buffer.write(chunk[0, count])
        end
        buffer.to_s
      end
    ensure
      client.try(&.close)
    end

    def self.parse_ensembl(body : String, local_chromosome : String, limit : Int32) : GeneTrack
      root = JSON.parse(body)
      if error = root.as_h?.try(&.["error"]?)
        raise error.as_s
      end
      entries = root.as_a? || raise "Ensembl response has no features"
      transcripts = [] of Hash(String, JSON::Any)
      gene_names = {} of String => String
      exons = Hash(String, Array(Tuple(UInt32, UInt32))).new { |hash, key| hash[key] = [] of Tuple(UInt32, UInt32) }
      entries.each do |entry|
        fields = entry.as_h? || next
        case string(fields["feature_type"]?)
        when "gene"
          if id = string(fields["id"]?)
            gene_names[id] = gene_name(fields["external_name"]?) || gene_name(fields["display_name"]?) || id
          end
        when "transcript"
          transcripts << fields
          return GeneTrack.notice(D4Plot.t("annotation.too_many", limit: limit)) if transcripts.size > limit
        when "exon"
          parent = string(fields["Parent"]?)
          first = integer(fields["start"]?)
          last = integer(fields["end"]?)
          if parent && first && last && first > 0 && last >= first && last <= UInt32::MAX
            exons[parent] << {first.to_u32, last.to_u32}
          end
        end
      end
      genes = [] of GeneModel
      transcripts.each do |fields|
        first = integer(fields["start"]?)
        last = integer(fields["end"]?)
        next unless first && last && first > 0 && last >= first && last <= UInt32::MAX
        id = string(fields["id"]?)
        parent = string(fields["Parent"]?)
        name = (parent && gene_names[parent]?) || gene_name(fields["external_name"]?) || id || D4Plot.t("annotation.unknown_gene")
        strand = integer(fields["strand"]?)
        direction = strand == 1 ? "+" : strand == -1 ? "-" : nil
        transcript_exons = id ? exons[id]? || [] of Tuple(UInt32, UInt32) : [] of Tuple(UInt32, UInt32)
        transcript_exons = transcript_exons.select { |(start1, end1)| start1 >= first && end1 <= last }.sort_by(&.[0])
        genes << GeneModel.new(local_chromosome, first.to_u32, last.to_u32, name, direction, transcript_exons)
      end
      return GeneTrack.notice(D4Plot.t("annotation.no_overlap")) if genes.empty?
      GeneTrack.new(genes)
    end

    def self.parse(body : String, genome : String, local_chromosome : String, limit : Int32) : GeneTrack
      root = JSON.parse(body).as_h
      raise root["error"].as_s if root["error"]?
      entries = root[track_for(genome)]?.try(&.as_a?) || raise "UCSC response has no gene track"
      return GeneTrack.notice(D4Plot.t("annotation.too_many", limit: limit)) if entries.size > limit
      genes = [] of GeneModel
      entries.each do |entry|
        fields = entry.as_h
        start0 = integer(fields["txStart"]? || fields["chromStart"]?)
        end0 = integer(fields["txEnd"]? || fields["chromEnd"]?)
        next unless start0 && end0 && start0 >= 0 && end0 > start0 && end0 <= UInt32::MAX
        name = if genome == "hs1"
                 gene_name(fields["geneName2"]?) || gene_name(fields["geneName"]?)
               else
                 gene_name(fields["geneName"]?) || gene_name(fields["geneName2"]?)
               end
        name ||= gene_name(fields["name2"]?) || gene_name(fields["name"]?) || D4Plot.t("annotation.unknown_gene")
        strand = string(fields["strand"]?)
        strand = nil unless strand == "+" || strand == "-"
        exons = parse_exons(fields, start0, end0)
        genes << GeneModel.new(local_chromosome, (start0 + 1).to_u32, end0.to_u32, name, strand, exons)
      end
      return GeneTrack.notice(D4Plot.t("annotation.no_overlap")) if genes.empty?
      GeneTrack.new(genes)
    end

    private def self.parse_exons(fields : Hash(String, JSON::Any), start0 : Int64, end0 : Int64) : Array(Tuple(UInt32, UInt32))
      starts = positions(fields["exonStarts"]?)
      ends = positions(fields["exonEnds"]?)
      if starts.empty? && ends.empty?
        sizes = positions(fields["blockSizes"]?)
        offsets = positions(fields["chromStarts"]?)
        starts = offsets.map { |offset| start0 + offset }
        ends = starts.zip(sizes).map { |(start, size)| start + size }
      end
      return [] of Tuple(UInt32, UInt32) unless starts.size == ends.size
      starts.zip(ends).compact_map do |(first, last)|
        if first >= start0 && last <= end0 && last > first && last <= UInt32::MAX
          {(first + 1).to_u32, last.to_u32}
        end
      end
    end

    private def self.positions(value : JSON::Any?) : Array(Int64)
      return [] of Int64 unless value
      if array = value.as_a?
        array.compact_map { |item| integer(item) }
      elsif string = value.as_s?
        string.split(',').compact_map(&.to_i64?)
      else
        [] of Int64
      end
    end

    private def self.integer(value : JSON::Any?) : Int64?
      value.try { |item| item.as_i64? || item.as_s?.try(&.to_i64?) }
    end

    private def self.string(value : JSON::Any?) : String?
      value.try(&.as_s?)
    end

    private def self.gene_name(value : JSON::Any?) : String?
      name = string(value)
      name unless name.nil? || name.empty? || name == "none"
    end
  end

  record PublicGeneRequest, id : Int32, source : String, genome : String, region : Region, limit : Int32
  record PublicGeneResult, request : PublicGeneRequest, track : GeneTrack

  class PublicGeneLoader
    alias Fetcher = Proc(String, String, String, Region, Int32, String)

    @mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @pending : PublicGeneRequest?
    @result : PublicGeneResult?
    @closed = false
    @generation = Atomic(Int32).new(0)
    @context : Fiber::ExecutionContext::Concurrent
    @finished = WaitGroup.new(1)
    @worker_error : Exception?

    def initialize(@fetcher : Fetcher = ->PublicGenes.fetch(String, String, String, Region, Int32))
      # Crystal 1.22's isolated event loop crashes while reading HTTPS sockets.
      # Use the same concurrent context as BackgroundIO for network requests.
      @context = Fiber::ExecutionContext::Concurrent.new("d4-plot-public-genes")
      @context.spawn do
        work
      rescue ex
        @worker_error = ex
      ensure
        @finished.done
      end
    end

    def submit(source : String, genome : String, region : Region, limit : Int32) : Int32
      PublicGenes.validate_source(source)
      PublicGenes.track_for(genome)
      id = @generation.add(1) + 1
      @mutex.synchronize do
        raise D4Plot.t("errors.viewer_closed") if @closed
        @pending = PublicGeneRequest.new(id, source, genome, region, limit)
        @result = nil
        @wake.signal
      end
      id
    end

    def poll : PublicGeneResult?
      @mutex.synchronize do
        result = @result
        @result = nil
        result
      end
    end

    def cancel : Nil
      @generation.add(1)
      @mutex.synchronize { @pending = @result = nil }
    end

    def close : Nil
      cancel
      @mutex.synchronize do
        @closed = true
        @wake.signal
      end
    end

    def wait : Nil
      @finished.wait
      if error = @worker_error
        raise error
      end
    end

    private def work : Nil
      while request = next_request
        next unless request.id == @generation.get
        track = begin
          if request.region.length > PublicGenes::MAX_REGION_SIZE
            GeneTrack.notice(D4Plot.t("annotation.zoom_in"))
          elsif request.source == "ensembl" && request.genome == "hs1"
            GeneTrack.notice(D4Plot.t("annotation.source_unavailable", genome: request.genome, source: "Ensembl"))
          elsif chromosome = request.source == "ucsc" ? PublicGenes.remote_chromosome(request.region.chromosome) : PublicGenes.ensembl_chromosome(request.region.chromosome)
            body = @fetcher.call(request.source, request.genome, chromosome, request.region, request.limit)
            if request.source == "ucsc"
              PublicGenes.parse(body, request.genome, request.region.chromosome, request.limit)
            else
              PublicGenes.parse_ensembl(body, request.region.chromosome, request.limit)
            end
          else
            GeneTrack.notice(D4Plot.t("annotation.chromosome_missing", chromosome: request.region.chromosome.inspect))
          end
        rescue ex
          GeneTrack.notice(D4Plot.t("annotation.public_unavailable", error: ex.message || ex.class.name))
        end
        @mutex.synchronize do
          @result = PublicGeneResult.new(request, track) unless @closed || request.id != @generation.get
        end
      end
    end

    private def next_request : PublicGeneRequest?
      @mutex.synchronize do
        while @pending.nil? && !@closed
          @wake.wait(@mutex)
        end
        request = @pending
        @pending = nil
        request
      end
    end
  end
end
