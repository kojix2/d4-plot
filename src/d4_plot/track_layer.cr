require "./i18n"
require "./view"

module D4Plot
  class TrackSource
    getter path : String
    getter name : String
    getter chromosomes : Hash(String, UInt32)
    getter denominator : Float64

    def initialize(
      @path : String,
      @name : String,
      @chromosomes : Hash(String, UInt32),
      @denominator : Float64,
    )
    end

    def_equals_and_hash path, name, chromosomes, denominator

    def key
      {path, name}
    end

    def label
      "#{File.basename(path)} / #{name.empty? ? D4Plot.t("app.default_track") : name}"
    end

    def self.load(path : String, cancelled : Proc(Bool)? = nil) : Array(TrackSource)
      path = File.realpath(path)
      sources = [] of TrackSource
      D4.open(path) do |file|
        file.each_track do |track|
          break if cancelled.try(&.call)
          chromosomes = track.chromosomes.reject { |chr| chr.size == 0 }.to_h { |chr| {chr.name, chr.size.to_u32} }
          sources << new(path, track.name, chromosomes, track.metadata.denominator) unless chromosomes.empty?
        end
      end
      raise ArgumentError.new(D4Plot.t("errors.no_tracks")) if sources.empty?
      sources
    end

    # Different contig sets are allowed; conflicting lengths are not silently
    # combined. Equal lengths still do not establish the reference assembly.
    def self.chromosomes(sources : Enumerable(TrackSource)) : Hash(String, UInt32)
      result = {} of String => UInt32
      sources.each do |source|
        source.chromosomes.each do |name, size|
          if previous = result[name]?
            raise ArgumentError.new(D4Plot.t("errors.conflicting_lengths", name: name, previous: previous, size: size)) if previous != size
          end
          result[name] = size
        end
      end
      result
    end

    # Returns a deterministic dictionary suitable for a shared browser
    # reference. If independently loaded tracks disagree about a contig
    # length, the first track supplies that reference length; the later track
    # is then marked incompatible by ReferenceCompatibility instead of making
    # every other track impossible to view. GUI layer loading still uses
    # #chromosomes above when it needs a conflict-free common dictionary.
    def self.reference_chromosomes(sources : Enumerable(TrackSource)) : Hash(String, UInt32)
      result = {} of String => UInt32
      sources.each do |source|
        source.chromosomes.each { |name, size| result[name] ||= size }
      end
      result
    end
  end

  class TrackLayer
    getter source : TrackSource
    property? visible = true
    property view : SampledView?
    property error : String?

    def initialize(@source); end
  end

  class LayerSample
    getter source : TrackSource
    getter view : SampledView?
    getter error : String?

    def initialize(@source : TrackSource, @view : SampledView?, @error : String?); end

    def_equals_and_hash source, view, error
  end
end
