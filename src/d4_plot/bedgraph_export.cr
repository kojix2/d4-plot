require "./view"

module D4Plot
  # Snapshot the bounded display bins before leaving the UI thread.
  class BedgraphExport
    @contents : String

    def initialize(@path : String, @sources : Array(String), source_path : String, source_name : String, view : SampledView)
      validate_chromosome!(view.region.chromosome)
      @contents = String.build do |io|
        io << "# Source: " << source_path.gsub(/[\r\n]/, " ") << "; track: " << source_name.gsub(/[\r\n]/, " ") << '\n'
        view.write_bedgraph(io)
      end
    end

    def write : Nil
      @sources.each do |source|
        if File.expand_path(@path) == File.expand_path(source) || same_existing_file?(@path, source)
          raise D4Plot.t("app.export_conflict")
        end
      end
      File.write(@path, @contents)
    end

    private def validate_chromosome!(chromosome : String) : Nil
      if chromosome.empty? || chromosome.each_char.any?(&.whitespace?) || chromosome.each_byte.any? { |byte| byte < 0x20_u8 || byte == 0x7f_u8 }
        raise ArgumentError.new("bedGraph cannot represent empty, whitespace, or control-character chromosome names")
      end
    end

    private def same_existing_file?(first : String, second : String) : Bool
      return false unless File.exists?(first) && File.exists?(second)
      File.same?(first, second)
    rescue File::NotFoundError
      false
    end
  end
end
