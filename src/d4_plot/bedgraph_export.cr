require "./view"

module D4Plot
  # Snapshot the bounded display bins before leaving the UI thread.
  class BedgraphExport
    @contents : String

    def initialize(@path : String, @sources : Array(String), source_path : String, source_name : String, view : SampledView)
      @contents = String.build do |io|
        io << "# Source: " << source_path.gsub(/[\r\n]/, " ") << "; track: " << source_name.gsub(/[\r\n]/, " ") << '\n'
        view.write_bedgraph(io)
      end
    end

    def write : Nil
      @sources.each do |source|
        if File.expand_path(@path) == File.expand_path(source) || (File.exists?(@path) && File.same?(@path, source))
          raise D4Plot.t("app.export_conflict")
        end
      end
      File.write(@path, @contents)
    end
  end
end
