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
      destination = File.expand_path(@path)
      @sources.each do |source|
        if destination == File.expand_path(source) || same_existing_file?(destination, source)
          raise D4Plot.t("app.export_conflict")
        end
      end
      write_atomically(destination)
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

    # Staging beside the destination keeps rename atomic. In particular, a
    # source hard link introduced after the checks above is replaced rather
    # than truncated by an in-place write.
    private def write_atomically(destination : String) : Nil
      File.tempfile(".d4-plot-bedgraph-", ".tmp", dir: File.dirname(destination)) do |file|
        file.print(@contents)
        file.close
        File.rename(file.path, destination)
      ensure
        file.close unless file.closed?
        File.delete?(file.path)
      end
    end
  end
end
