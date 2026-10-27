require "bigwig"
require "d4"
require "./track_layer"

module D4Plot
  # Stream the complete, unsampled D4 track into a native BigWig writer.
  class BigWigExport
    getter path : String

    def self.destination(chosen_path : String) : String
      return chosen_path if chosen_path.downcase.ends_with?(".bw") || chosen_path.downcase.ends_with?(".bigwig")
      path = "#{chosen_path}.bw"
      raise D4Plot.t("app.image_exists", name: File.basename(path)) if File.exists?(path)
      path
    end

    def initialize(@path : String, @sources : Array(String), @source : TrackSource); end

    def write : Nil
      destination = File.expand_path(@path)
      ensure_safe_destination!(destination)
      chromosomes = @source.chromosomes.keys.sort!.map { |name| {name, @source.chromosomes[name]} }
      raise ArgumentError.new("The selected D4 track has no chromosomes") if chromosomes.empty?

      D4.open(@source.path) do |file|
        track = file.track(@source.name)
        denominator = track.metadata.denominator
        raise ArgumentError.new("Invalid D4 denominator") unless denominator.finite? && denominator > 0.0
        raise ArgumentError.new("The D4 source changed during export") unless denominator == @source.denominator
        chromosomes.each do |name, length|
          raise ArgumentError.new("The D4 source changed during export") unless track.chromosome_size(name) == length
        end

        BigWig.create(destination, chromosomes, options: BigWig::WriteOptions.new(overwrite: true)) do |writer|
          chromosomes.each do |name, _length|
            track.each_interval(name) do |interval|
              value = interval.value.to_f64 / denominator
              raise ArgumentError.new("D4 signal exceeds BigWig's Float32 range") unless value.finite? && value.abs <= Float32::MAX
              writer.add(name, interval.left, interval.right, value)
            end
          end
          ensure_safe_destination!(destination)
        end
      end
    end

    private def ensure_safe_destination!(destination : String) : Nil
      @sources.each do |source|
        if destination == File.expand_path(source) || (File.exists?(destination) && File.exists?(source) && File.same?(destination, source))
          raise D4Plot.t("app.export_conflict")
        end
      end
    end
  end
end
